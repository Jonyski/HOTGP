{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE TupleSections #-}

-- |
-- Module      : Evolution.SamplerTable
-- Description : Pre-computed, type-directed random tree generator.
--
-- This is the heart of the \"typed\" in Higher-Order Typed GP: it makes it
-- possible to grow a random program that is /well-typed by construction/,
-- so the search never wastes an evaluation on a program that would not
-- compile.
--
-- The problem it solves
-- ---------------------
-- Given \"I need a tree of depth @d@ producing type @t@\", which node should
-- I put at the root? Naively picking a random operation produces garbage
-- (a @head@ where an @Int@ is needed, wrong arity, etc.). The table
-- pre-computes, for every combination of (remaining depth, required output
-- type), the list of choices that are legal there.
--
-- The table
-- ---------
-- A 'SamplerTable' is
--
-- @
-- Map (Depth, OutputType) (UsesInput, [Either terminal operation])
-- @
--
-- i.e. for each key, \"which terminals and which operations can I place here,
-- given I must still produce this type within this remaining depth?\".
-- Sampling is then a simple uniform choice from that list, recursing into
-- each child with @depth - 1@.
--
-- Two subtleties are baked into the table:
--
-- * /full vs grow/ - @forceFullTree@ decides whether the table may offer
--   terminals at depth > 0. For a \"full\" tree terminals are only legal at
--   depth 0, forcing every branch to reach the bottom; for \"grow\" they are
--   offered at every level, so branches may stop early.
-- * /UsesInput/ - each row tracks whether any of its choices can consume a
--   program argument. This is used to reject /vacuous/ lambdas: a lambda
--   whose body ignores its parameter is pointless, so 'generateLambda'
--   retries until the body actually uses its input.
--
-- Higher-order operations (@map@, @filter@) are handled by building a
-- /nested/ table for the lambda body (one \"lambda level\" deeper, see
-- 'maxLambdaDepthAtEachLevel'), whose arguments are the lambda's own
-- parameters rather than the program's.

module Evolution.SamplerTable (buildTree, buildTable, SamplerTable, TermsAndOps (..), typesToArgMap, instantiateArgs) where

import Control.Monad (guard)
import qualified Control.Monad.State.Strict as State
import Data.Bifunctor
import Data.Bitraversable (bisequence)
import Data.List (find)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isNothing, mapMaybe, maybeToList)
import qualified Data.Set as S
import Evolution.Core (Depth, St)
import Evolution.Helpers (sample)
import Grammar
import qualified System.Random as R

-- | Everything a problem allows a generated program to contain, grouped by
-- the type each entry produces.
--
-- Built once per benchmark (see "Benchmark.BenchmarkToConfig"): the
-- arguments the program receives, the constants it may embed, and the
-- operations that are relevant to it (already filtered down to the types
-- the benchmark declares interesting).
data TermsAndOps = MkTermsAndOps
  { -- | Program arguments available at each type: @type -> [arg indexes]@.
    _arguments :: !(M.Map OutputType [Int]),
    -- | Constant-generating actions at each type. Kept as 'St' actions (not
    -- values) because some constants are random (e.g. any integer in
    -- @[-1000,1000]@), so they must be drawn at sampling time.
    _literals :: !(M.Map OutputType [St Lit]),
    -- | Operations that can produce each type.
    _operations :: !(M.Map OutputType [Operation])
  }

-- | Did a generated branch consume a program argument?
--
-- A two-point semigroup: anything combined with @UsesInput@ is
-- @UsesInput@. Folding it over a list of choices answers \"can this row
-- produce a tree that reads its inputs?\".
data UsesInput = UsesInput | DoesNotUseInput

instance Semigroup UsesInput where
  (<>) :: UsesInput -> UsesInput -> UsesInput
  DoesNotUseInput <> DoesNotUseInput = DoesNotUseInput
  _ <> _ = UsesInput

instance Monoid UsesInput where
  mempty :: UsesInput
  mempty = DoesNotUseInput

-- | One cell of the table: a usage flag plus the alternatives.
--
-- Each alternative is either a terminal-producing action ('Left') or an
-- operation together with the instantiation of its signature that makes it
-- fit this cell ('Right'). The type is an action rather than a value so
-- random literals stay deferred until the node is actually sampled.
type SamplerTableRow = (UsesInput, [Either (St Terminal) (St (Operation, FunctionType))])

-- | The table: keyed by remaining depth and required output type.
type SamplerTable = M.Map (Depth, OutputType) SamplerTableRow

-- | How deep a lambda body may be, per nesting level: the outer lambda may
-- be 3 levels deep, a lambda inside a lambda must be a leaf expression
-- (depth 0, i.e. effectively only @id@-like bodies).
--
-- Nesting is capped because the number of table cells grows with the number
-- of levels, and deeply nested lambdas are rarely useful.
maxLambdaDepthAtEachLevel :: [Depth]
maxLambdaDepthAtEachLevel = [3, 0]

-- | Number of lambda nesting levels supported (length of the list above).
maxLambdaLevel :: Int
maxLambdaLevel = length maxLambdaDepthAtEachLevel

-- | Generates a tree of at most the given depth producing the given type,
-- by sampling choices out of a pre-built table.
--
-- This is the only entry point needed by "Evolution.Generate"; everything
-- about which nodes are legal has already been decided when the table was
-- built, so this function is a straightforward recursive descent.
buildTree :: SamplerTable -> Depth -> OutputType -> St Tree
buildTree _ depth _ | depth < 0 = error "Negative depth!"
buildTree table depth outputType = do
  node <- sample $ snd $ table M.! (depth, outputType)
  case node of
    Left stTerm -> mkLeaf <$> stTerm
    Right st -> do
      (op, fType) <- st
      -- Each child gets one less depth unit, so the tree cannot exceed the
      -- requested depth; children are sampled independently.
      args <- sequence $ buildTree table (depth - 1) <$> _argTypes fType
      return $ op <| args

-- | Builds a sampler table for the top level (no enclosing lambda).
--
-- @forceFullTree@ selects the \"full\" variant (used by 'Evolution.Generate.full')
-- when 'True', and the \"grow\" variant otherwise.
buildTable :: TermsAndOps -> Depth -> Bool -> SamplerTable
buildTable = buildTableForLevel 0

-- | Recursive worker behind 'buildTable'.
--
-- @currentLambdaLevel@ tracks how many lambdas deep we are (0 = at the
-- program's top level), which both limits nesting and decides which
-- argument set is visible (the program's arguments at level 0, the
-- enclosing lambda's parameters below that).
buildTableForLevel :: Int -> TermsAndOps -> Depth -> Bool -> SamplerTable
buildTableForLevel currentLambdaLevel (MkTermsAndOps args literals ops) maxDepth forceFullTree = mapping
  where
    maxLambdaDepth = maxLambdaDepthAtEachLevel !! currentLambdaLevel
    -- Terminals available here: program/lambda arguments (flagged as using
    -- an input) unioned with the allowed constants (never using an input).
    terms, argMap, litMap :: M.Map OutputType (UsesInput, [St Terminal])
    argMap = M.map ((\x -> (if null x then DoesNotUseInput else UsesInput, x)) . fmap (return . Arg)) args
    litMap = M.map ((DoesNotUseInput,) . fmap (fmap Literal)) literals
    terms = M.unionWith (<>) argMap litMap
    -- Every type that appears anywhere in the grammar slice: these are the
    -- rows we need to materialise.
    relevantTypes = S.toList $ S.union (M.keysSet terms) (M.keysSet ops)
    mapping :: SamplerTable
    mapping =
      M.fromList $ do
        depth <- [0 .. maxDepth]
        outputType <- relevantTypes
        return ((depth, outputType), buildTableRow (depth, outputType))

    -- One nested table per lambda type we might want to generate. Each is
    -- built one lambda level deeper, with the lambda's parameters replacing
    -- the program's arguments.
    lambdaMappings :: M.Map FunctionType SamplerTable
    lambdaMappings = M.fromList $ do
      typeCandidate <- relevantTypes
      case typeCandidate of
        GLambda ft ->
          -- if the level is zero, only id is an option, so it must be a -> a
          if maxLambdaDepth == 0 && head (_argTypes ft) /= _outType ft
            then []
            else
              let args = typesToArgMap (_argTypes ft)
                  table = buildTableForLevel (currentLambdaLevel + 1) (MkTermsAndOps args literals ops) maxLambdaDepth False
               in case table M.!? (maxLambdaDepth, _outType ft) of
                    Nothing -> [] -- the body type is unreachable: no lambda
                    Just (DoesNotUseInput, _) -> [] -- body would ignore its parameter: reject
                    Just (_, []) -> [] -- nothing to sample: reject
                    Just _ -> [(ft, table)]
        _ -> []

    -- Decide the alternatives for one (depth, type) cell.
    buildTableRow :: (Depth, OutputType) -> (UsesInput, [Either (St Terminal) (St (Operation, FunctionType))])
    -- Lambda cells are special: at depth 0 the only choice (if any) is a
    -- lambda literal built from the nested table above; operations cannot
    -- produce a function type here.
    -- a special case is made for generating lambdas
    buildTableRow (0, GLambda ft)
      | currentLambdaLevel == maxLambdaLevel = mempty -- nesting exhausted
      | otherwise = (mempty, maybeToList $ Left . generateLambda maxLambdaDepth ft <$> lambdaMappings M.!? ft)
    -- At depth 0 every branch must terminate: only terminals are legal.
    buildTableRow (0, outType) = maybe mempty (fmap (fmap Left)) (terms M.!? outType)
    -- Deeper cells may either stop early (terminals, only in grow mode) or
    -- continue with an operation whose children are built at depth-1.
    buildTableRow (depth, outType) = terminals <> operations
      where
        getMapping (depth, t) = fromMaybe mempty (mapping M.!? (depth, t))
        terminals, operations :: (UsesInput, [Either (St Terminal) (St (Operation, FunctionType))])
        terminals
          | forceFullTree = mempty -- "full" trees must reach the bottom
          | otherwise = getMapping (0, outType)
        operations =
          bimap mconcat (Right <$>) $
            unzip $ do
              op <- fromMaybe [] $ ops M.!? outType
              let possibleArgs = instantiateArgs relevantTypes outType op
                  -- For each child type, which depths may it occupy? A full
                  -- tree pins the child to exactly mDepth; a grow tree lets
                  -- it use anything from 0 up to mDepth.
                  rowsToCheck :: Depth -> GType -> [SamplerTableRow]
                  rowsToCheck mDepth t
                    | forceFullTree = [getMapping (mDepth, t)] -- if we're forcing a full, the child tree must have mDepth
                    | otherwise = [getMapping (d, t) | d <- [0 .. mDepth]] -- if it's not full, check every depth from here below
                  -- An operation is unusable if some child has no legal
                  -- choices at any admissible depth.
                  isMappingEmpty :: Depth -> GType -> Bool
                  isMappingEmpty mDepth t = all (null . snd) $ rowsToCheck mDepth t

                  areArgsValid :: ArgTypes -> Bool
                  areArgsValid argTypes = not (any (isMappingEmpty (depth - 1)) argTypes)

                  -- Does this instantiation have at least one branch that
                  -- reads an argument? Used later as the row's flag.
                  mappingUsesInput :: Depth -> GType -> UsesInput
                  mappingUsesInput mDepth t = foldMap fst $ rowsToCheck mDepth t

                  doArgsUseInput :: ArgTypes -> UsesInput
                  doArgsUseInput argTypes = foldMap (mappingUsesInput (depth - 1)) argTypes

                  validArgs = filter areArgsValid possibleArgs
                  build :: St ArgTypes -> St (Operation, FunctionType)
                  build = fmap (\arg -> (op, arg ->> outType))
              guard $ (not . null) validArgs -- no legal instantiation: skip this op
              return (foldMap doArgsUseInput validArgs, build $ sample validArgs)

-- | Draws a lambda literal for the given signature, retrying until its body
-- actually uses the lambda's parameter.
--
-- Why retry instead of filtering up front: the table only knows whether the
-- body /could/ use an input, not whether a particular draw did - so the
-- cheap and simple fix is to re-sample. The check 'hasInput' below is a
-- plain syntactic test (does any @LeafArg@ appear?).
generateLambda :: Depth -> FunctionType -> SamplerTable -> St Terminal
generateLambda maxDepth ft table = do
  tree <- buildTree table maxDepth $ _outType ft
  if hasInput tree -- always generate lambdas that use their inputs
    then return $ Literal $ LambdaLit $ MkTypedTree tree ft
    else generateLambda maxDepth ft table
  where
    hasInput :: Tree -> Bool
    hasInput (LeafArg _) = True
    hasInput (LeafLit _) = False
    hasInput Node {_args = trs} = any hasInput trs

-- | Groups argument indexes by their type: @[Int, Bool]@ becomes
-- @{Int -> [0], Bool -> [1]}@.
--
-- Used to expose a lambda's parameters to its body table.
typesToArgMap :: [GType] -> M.Map GType [Int]
typesToArgMap types = M.fromListWith (<>) $ zipWith (\i t -> (t, [i])) [0 ..] types

-- | Returns a list of possible arg types that make the operation satisfy the output type
--
-- This is the type-instantiation step: an operation like
-- @map :: (a -> b) -> [a] -> [b]@ can produce many concrete signatures, and
-- this enumerates the ones that (a) unify with the required output type and
-- (b) only mention types the benchmark considers relevant.
--
-- Example: wanting an @[Int]@ from @map@ yields
-- @[([Int] -> Bool, [Int]), ([Int] -> Int, [Int]), ...]@ - every lambda
-- returning a relevant type.
instantiateArgs ::
  -- | what types are allowed
  [GType] ->
  -- | the desired output type for the operation
  OutputType ->
  -- | the operation
  Operation ->
  [ArgTypes]
instantiateArgs relevantTypes desiredOutputType op = case unifyTypes desiredOutputType (opOutput op) of
  -- The operation cannot produce this type at all.
  Nothing -> []
  -- It can: propagate the unification result into the argument types
  -- (learnTypes gives the bindings implied by output = desired), then
  -- enumerate concrete choices for each remaining argument.
  Just gt ->
    getPossibilities
      (opArgTypes op)
      relevantTypes
      (learnTypes (opOutput op, gt))
  where
    -- Walks the argument types left to right, threading the set of
    -- type-variable bindings discovered so far, and returns every concrete
    -- instantiation consistent with them.
    getPossibilities :: ArgTypes -> [GType] -> [(GType, GType)] -> [[GType]]
    getPossibilities [] relevantTypes constraints = return []
    getPossibilities (a : as) relevantTypes constraints = case checkConstraints constraints a of
      -- This argument is (or contains) a variable already decided by an
      -- earlier argument or by the output: it must be that type, and only
      -- the relevant types that unify with it are legal choices.
      Just xs -> do
        x <- mapMaybe (unifyTypes xs) relevantTypes
        ps <- getPossibilities as relevantTypes (constraints <> learnTypes (a, x))
        return (x : ps)
      -- Not yet decided: branch over every relevant type that unifies,
      -- extending the constraints with each choice.
      Nothing -> do
        (t, cs) <- zip possibleTypes newConstraints
        ps <- getPossibilities as relevantTypes (constraints <> cs)
        return (t : ps)
      where
        possibleTypes = mapMaybe (unifyTypes a) relevantTypes
        newConstraints = (\t -> learnTypes (a, t)) <$> possibleTypes

    -- Applies the accumulated bindings to an argument type, yielding the
    -- type it must actually take (or Nothing if the constraints conflict
    -- with its structure).
    checkConstraints :: [(GType, GType)] -> GType -> Maybe GType
    checkConstraints constraints (GPoly n) = snd <$> find ((== GPoly n) . fst) constraints
    checkConstraints constraints (GList x) = GList <$> checkConstraints constraints x
    checkConstraints constraints (GPair a b) = case (checkConstraints constraints a, checkConstraints constraints b) of
      (Just ra, Just rb) -> Just (GPair ra rb)
      (Just ra, Nothing) -> Just (GPair ra b)
      (Nothing, Just rb) -> Just (GPair a rb)
      (Nothing, Nothing) -> Nothing
    checkConstraints constraints (GLambda (MkFunctionType args out)) =
      if isNothing o && as == args
        then Nothing
        else Just $ GLambda (MkFunctionType as (fromMaybe out o))
      where
        as = zipWith fromMaybe args (checkConstraints constraints <$> args)
        o = checkConstraints constraints out
    checkConstraints _ x = Just x -- concrete type: already fully known
