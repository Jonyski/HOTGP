{-# LANGUAGE OverloadedLists #-}

-- |
-- Module      : Grammar.Types
-- Description : Type signatures of the primitives and the type checker.
--
-- This module answers two questions about any 'Tree':
--
-- /What type does each primitive have?/ - 'opType' gives the (possibly
-- polymorphic) signature of every 'Operation', the equivalent of a Haskell
-- @:i@ for the grammar.
--
-- /Is this tree well-typed?/ - 'typeCheck' walks a tree and unifies the
-- required type with what the tree actually produces, instantiating type
-- variables (@GPoly n@) as it goes. This is what makes the search
-- /type-aware/: invalid programs are rejected before they are ever run on
-- test cases.
--
-- The algorithm is a small, monomorphic variant of Hindley-Milner
-- unification. There are no nested type variables to generalise (no @forall@
-- inside the language), so 'unifyTypes' can be a simple structural match.
--
-- Read this module after "Grammar.Core", and before "Grammar.Eval" (which
-- relies on the assumption that everything it evaluates was type-checked).
module Grammar.Types where

import Control.Monad (zipWithM)
import qualified Data.Vector as V
import Grammar.Core
import Grammar.Pretty

-- | Given an operation, returns its required (potentially polymorphic) input and output type.
--
-- This table is the single source of truth for the grammar's signature; it is
-- used by the type checker, the type-directed sampler
-- ("Evolution.SamplerTable") and the pruner.
--
-- Polymorphic entries instantiate their type variables consistently across
-- the whole signature. For example:
--
-- @
-- opType If    = [GBool, a, a]  ->> a     -- if  :: Bool -> a -> a -> a
-- opType Map   = [(a -> b), [a]] ->> [b]  -- map :: (a -> b) -> [a] -> [b]
-- opType Zip   = [[a], [b]]      ->> [(a,b)]
-- @
--
-- Note @If@ uses the /same/ variable index (0) in both branches, which is how
-- the checker learns that both branches must agree.
opType :: Operation -> FunctionType
-- Int
opType AddInt = [GInt, GInt] ->> GInt
opType SubInt = [GInt, GInt] ->> GInt
opType MultInt = [GInt, GInt] ->> GInt
opType DivInt = [GInt, GInt] ->> GInt
opType ModInt = [GInt, GInt] ->> GInt
opType MaxInt = [GInt, GInt] ->> GInt
opType MinInt = [GInt, GInt] ->> GInt
-- Bool
opType And = [GBool, GBool] ->> GBool
opType Or = [GBool, GBool] ->> GBool
opType Not = [GBool] ->> GBool
opType If = [GBool, GPoly 0, GPoly 0] ->> GPoly 0
-- Float
opType AddFloat = [GFloat, GFloat] ->> GFloat
opType SubFloat = [GFloat, GFloat] ->> GFloat
opType MultFloat = [GFloat, GFloat] ->> GFloat
opType DivFloat = [GFloat, GFloat] ->> GFloat
opType Sqrt = [GFloat] ->> GFloat
-- List
opType Reverse = [GList $ GPoly 0] ->> GList (GPoly 0)
opType Singleton = [GPoly 0] ->> GList (GPoly 0)
opType Cons = [GPoly 0, GList $ GPoly 0] ->> GList (GPoly 0)
opType Head = [GList $ GPoly 0] ->> GPoly 0
opType Concat = [GList $ GList $ GPoly 0] ->> GList (GPoly 0)
-- Pair
opType ToPair = [GPoly 0, GPoly 1] ->> GPair (GPoly 0) (GPoly 1)
opType Fst = [GPair (GPoly 0) (GPoly 1)] ->> GPoly 0
opType Snd = [GPair (GPoly 0) (GPoly 1)] ->> GPoly 1
-- Char + Bool
opType EqChar = [GChar, GChar] ->> GBool
opType IsLetter = [GChar] ->> GBool
opType IsDigit = [GChar] ->> GBool
-- Float + Int
opType IntToFloat = [GInt] ->> GFloat
opType Floor = [GFloat] ->> GInt
-- Int + Bool
opType GtInt = [GInt, GInt] ->> GBool
opType LtInt = [GInt, GInt] ->> GBool
opType EqInt = [GInt, GInt] ->> GBool
-- List + Int
opType Range = [GInt, GInt, GInt] ->> GList GInt
opType Len = [GList $ GPoly 0] ->> GInt
opType SumInts = [GList GInt] ->> GInt
opType ProductInts = [GList GInt] ->> GInt
opType Take = [GInt, GList $ GPoly 0] ->> GList (GPoly 0)
-- List + Float
opType SumFloats = [GList GFloat] ->> GFloat
opType ProductFloats = [GList GFloat] ->> GFloat
-- List + Char
opType Unlines = [GList (GList GChar)] ->> GList GChar
-- List + Char + Int
opType ShowInt = [GInt] ->> GList GChar
-- List + Pair
opType Zip = [GList (GPoly 0), GList (GPoly 1)] ->> GList (GPair (GPoly 0) (GPoly 1))
-- List + Lambda
opType Map = [GLambda ([GPoly 0] ->> GPoly 1), GList $ GPoly 0] ->> GList (GPoly 1)
opType Filter = [GLambda ([GPoly 0] ->> GBool), GList $ GPoly 0] ->> GList (GPoly 0)

-- | Given an operation, returns its required (potentially polymorphic) input type.
--
-- @opArgTypes = _argTypes . opType@
opArgTypes :: Operation -> ArgTypes
opArgTypes = _argTypes . opType

-- | Given an operation, returns its (potentially polymorphic) output type.
--
-- @opOutput = _outType . opType@
opOutput :: Operation -> OutputType
opOutput = _outType . opType

-- | Given a literal, returns its type.
--
-- Literals are always monomorphic: the only place a type variable could hide
-- is an empty list, which is why 'ListLit' carries its element type.
litType :: Lit -> OutputType
litType (IntLit n) = GInt
litType (FloatLit x) = GFloat
litType (BoolLit b) = GBool
litType (CharLit s) = GChar
litType (PairLit a b) = GPair (litType a) (litType b)
litType (ListLit t trees) = GList t -- this assumes homogenous lists
litType (LambdaLit tt) = GLambda $ _type tt

-- | Given the arguments of a program, gets the output type of a tree in that context.
--
-- Only leaves need this: for @Arg n@ we look up the n-th parameter of the
-- enclosing program (or lambda), for a literal we ask 'litType'. Internal
-- nodes get their type straight from their operation, independent of context.
getType :: ProgramArgTypes -> Tree -> OutputType
getType pgTypes Leaf {_terminal = (Arg n)} = pgTypes !! n
getType pgTypes Leaf {_terminal = (Literal lit)} = litType lit
getType pgTypes Node {_operation = op} = opOutput op

-- | Unifies two types to their most specialized version.
-- Will fail ('Nothing') for two distinct concrete types.
--
-- Rules, in order of precedence:
--
-- * a type variable unifies with /anything/ and is bound to it (the variable
--   side disappears - there is no substitution environment, the result simply
--   is the concrete type);
-- * pairs, lists and lambdas unify structurally, provided every component
--   unifies;
-- * otherwise the two types must be equal.
--
-- Example: @unifyTypes (GPoly 0) (GList GInt) == Just (GList GInt)@, while
-- @unifyTypes GInt GBool == Nothing@.
unifyTypes :: GType -> GType -> Maybe GType
unifyTypes (GPoly n) x = Just x
unifyTypes x (GPoly n) = Just x
unifyTypes (GPair a b) (GPair x y) = GPair <$> unifyTypes a x <*> unifyTypes b y
unifyTypes (GList a) (GList x) = GList <$> unifyTypes a x
unifyTypes (GLambda (MkFunctionType args1 out1)) (GLambda (MkFunctionType args2 out2)) = do
  args <- zipWithM unifyTypes args1 args2
  out <- unifyTypes out1 out2
  return $ GLambda $ MkFunctionType args out
unifyTypes a b = if a == b then Just a else Nothing

-- | Checks if a tree matches the (potentially polymorphic) expected type,
-- given the program argument types.
--
-- If it succeeds, returns the specialized concrete version of the output
-- type; if it fails, returns 'Nothing' and the tree must be discarded.
--
-- How it works, top-down:
--
-- 1. Unify the required type with what this node produces. For a variable
--    this instantiates it (a required @a@ satisfied by an @Int@ leaf makes
--    the rest of the signature expect @Int@).
-- 2. For a 'Node', take the operation's signature. If the operation's own
--    output was a variable (e.g. @if@ returning @a@), the instantiated type
--    is substituted into /all/ of its argument types, so both branches are
--    forced to agree with the context.
-- 3. Recurse into the children with the appropriate expected types
--    ('typeCheckArgs'), instantiating an expected variable with whatever the
--    child actually produced - this is how @map f [1,2,3]@ learns that its
--    lambda must be @Int -> ...@.
typeCheck :: ProgramType -> Tree -> Maybe OutputType
typeCheck (MkFunctionType pgArgs requiredType) t@Leaf {} = unifyTypes requiredType $ getType pgArgs t
typeCheck (MkFunctionType pgArgs requiredType) Node {_operation = op, _args = children} = do
  outType <- unifyTypes requiredType (opOutput op)
  let defaultArgTypes = opArgTypes op
      argTypes = case opOutput op of
        GPoly n -> replace (opOutput op) outType defaultArgTypes
        gt -> defaultArgTypes
  if typeCheckArgs pgArgs argTypes children
    then Just outType
    else Nothing
  where
    -- Walks the expected argument types against the actual children,
    -- threading the instantiation of type variables from left to right.
    typeCheckArgs :: ProgramArgTypes -> [GType] -> [Tree] -> Bool
    typeCheckArgs pgArgs [] [] = True
    typeCheckArgs pgArgs [] _ = False
    typeCheckArgs pgArgs _ [] = False
    typeCheckArgs pgArgs (expectedType : ets) (t : ts) = case typeCheck (pgArgs ->> expectedType) t of
      Nothing -> False
      Just gt -> case expectedType of
        -- If the expected type was a variable, the child decided what it
        -- stands for; make the remaining arguments use the same choice.
        GPoly n -> typeCheckArgs pgArgs (replace (GPoly n) gt ets) ts
        et -> typeCheckArgs pgArgs ets ts
    -- Plain list substitution of one type for another.
    replace :: Eq a => a -> a -> [a] -> [a]
    replace old new = map (\el -> if el == old then new else el)

-- | Given the available program types, infers the output type of a tree.
--
-- This is the /dual/ of 'typeCheck': instead of asking \"does this fit the
-- required type?\" it asks \"what does this end up being?\". It is mainly
-- useful to determine the type for trees with many polymorphic nodes, where
-- walking bottom-up and learning from the arguments is easier than unifying
-- top-down.
--
-- Leaves are concrete, so their type is immediate. For a node, we first
-- infer each child's type, pair each expected argument type with the child's
-- actual type ('learnTypes'), and then replace the node's output variable
-- with whatever the pairing revealed.
inferOutputType :: ProgramArgTypes -> Tree -> OutputType
inferOutputType pgTypes l@Leaf {} = getType pgTypes l -- Leafs are always concrete
inferOutputType pgTypes Node {_operation = op, _args = ch} = replacePoly $ opOutput op
  where
    lookup n = snd $ head $ filter ((== GPoly n) . fst) $ learnTypes =<< zip (opArgTypes op) (inferOutputType pgTypes <$> ch)
    replacePoly (GPoly n) = lookup n
    replacePoly (GList a) = GList (replacePoly a)
    replacePoly (GPair a b) = GPair (replacePoly a) (replacePoly b)
    replacePoly (GLambda (MkFunctionType args o)) = GLambda (MkFunctionType (replacePoly <$> args) (replacePoly o))
    replacePoly t = t

-- | Pairs an expected type with an actual type and reports the type-variable
-- bindings that the pairing implies, descending into containers.
--
-- @learnTypes ([a], [Int]) == [(a, Int)]@ - the element variable @a@ must be
-- @Int@. Because the caller uses @=<<@ over a list of pairs, all bindings
-- found across all arguments are pooled together; a variable that never
-- appears on the left (concrete expected type) simply contributes nothing.
learnTypes :: (GType, GType) -> [(GType, GType)]
learnTypes (GList a, GList b) = learnTypes (a, b)
learnTypes (GPair a b, GPair x y) = learnTypes (a, x) <> learnTypes (b, y)
learnTypes (GLambda (MkFunctionType as b), GLambda (MkFunctionType xs y)) = learnTypes (b, y) <> concat (zipWith (curry learnTypes) as xs)
learnTypes (x, y) = [(x, y)]