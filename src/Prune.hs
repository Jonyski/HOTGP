-- |
-- Module      : Prune
-- Description : Post-processing: greedily shrink a found program without
--               losing accuracy.
--
-- Genetic programming tends to find /correct but bloated/ programs -
-- subtrees that compute something the rest of the program never really
-- needs. This module removes them after the fact.
--
-- The tool is run from the CLI (@stack run prune@) and works on the JSON
-- result files produced by a finished run:
--
-- @
-- input-prune/*.result.json   -- programs produced by a run
-- output-prune/*.result.json  -- the same files plus pruned-program fields
-- @
--
-- How pruning works
-- -----------------
-- 'pruneTree' walks every position of the tree in order ('nextPath') and,
-- at each one, considers replacing the subtree rooted there with any of its
-- own subtrees ('replaceWithSubtrees' - i.e. \"delete the wrapper node and
-- promote a child in its place\"). The candidate is accepted only if it
-- scores better under 'compareTrees', which ranks programs by
--
-- 1. /higher/ accuracy on the training set (note @1 - acc@ is minimised),
-- 2. then /smaller/ height,
-- 3. then /smaller/ node count.
--
-- So accuracy is never sacrificed; size is only used to break ties. The
-- walk continues until no single-node deletion improves the ranking, which
-- is a classic greedy (hill-climbing) simplification.
--
-- A special case exists for @map@: an @a -> b@ lambda with @a == b@ can be
-- removed entirely (the list can be promoted directly), which the generic
-- \"promotable argument\" check cannot express for polymorphic operations.
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}

module Prune where

import Benchmark
import Benchmark.Dataset
import Benchmark.Log
import Data.Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Key as K
import Data.Bifunctor (Bifunctor (bimap))
import Data.Foldable (minimumBy)
import Data.Function (on)
import Data.HashMap.Strict (fromList, (!?))
import Data.Text (pack, replicate, unpack)
import Grammar (Tree, bLitT, getHeight, getNodeCount, iLitT, lambdaLitT)
import Grammar.Core
import Grammar.Helpers (computeMeasure, resetMeasure)
import Grammar.Simplify
import Grammar.Types
import Pretty (Pretty (pretty))
import System.Directory

-- | Prunes all trees within the input-prune and saves them into output-prune
--
-- Reads every file in @input-prune/@, prunes the program it describes, and
-- writes the result (original JSON plus the new fields) to @output-prune/@.
-- Both directories are expected to exist.
prune :: IO ()
prune = do
  paths <- listDirectory "input-prune"
  mapM_ pruneFile paths

-- | Prunes a single result JSON.
--
-- Pipeline per file:
-- 1. read the original program out of the @showTree@ field (it was written
--    with 'show', so it round-trips through 'read');
-- 2. load the problem's train/test sets (the dataset name is in the JSON) -
--    the same split the run used, so accuracy numbers are comparable;
-- 3. greedily prune, then 'simplifyTree' for the human-readable variant;
-- 4. write a new JSON containing the pruned program plus before/after
--    accuracy and size, keeping every original field.
pruneFile :: FilePath -> IO ()
pruneFile fileName = do
  putStrLn fileName
  Just (Object content) <- decodeFileStrict ("input-prune/" <> fileName) :: (IO (Maybe Value))
  let Just (String showTree) = KM.lookup (K.fromString "showTree") content
      Just (String datasetNameText) = KM.lookup (K.fromString "datasetName") content
      datasetName = unpack datasetNameText
      -- Measures are stripped before reading because the stored tree's
      -- cached depths refer to its original position in a larger tree.
      tree = resetMeasure $ read $ unpack showTree

  (trainSet, testSet) <- case getProblem datasetName of
    Just (MkProblem problem) -> loadTrainAndTestSet "./" problem
    _ -> undefined

  let prunedTree = computeMeasure $ pruneTree trainSet tree
      (Object newJson) =
        object
          [ "showPrunedTree" .= show prunedTree,
            "stringRepPruned" .= pretty prunedTree,
            "stringRepPrunedSimple" .= pretty (simplifyTree prunedTree),
            "trainAccuracy" .= getAcc trainSet tree,
            "testAccuracy" .= getAcc testSet tree,
            "trainAccuracyPruned" .= getAcc trainSet prunedTree,
            "testAccuracyPruned" .= getAcc testSet prunedTree,
            "heightPruned" .= getHeight prunedTree,
            "nodeCountPruned" .= getNodeCount prunedTree
          ]

  encodeFile ("output-prune/" <> fileName) (Object $ content <> newJson)

-- | Accuracy of a tree on a dataset (the first component of
-- 'getAccuracyAndNmse').
getAcc :: Dataset -> Tree -> Float
getAcc dataset = fst . getAccuracyAndNmse dataset

-- | A location inside a tree: the chain of child indexes from the root.
--
-- @[]@ is the root, @[0,2]@ is the third child of the first child. Lambda
-- bodies are /not/ a new level here: paths address the enclosing tree and
-- the lambda helpers below dive into bodies transparently.
type TreePath = [Int]

-- | The greedy pruning loop.
--
-- Starting from the better of (original, once-simplified) trees, it
-- repeatedly visits positions in order:
--
-- * at the current position, try every single-node deletion; if the best
--   deletion beats the current tree, descend into it and keep trying from
--   the same position;
-- * otherwise advance to the next position ('nextPath') and continue;
-- * when positions run out, return the tree.
--
-- Terminates because each accepted step strictly improves the ranking of a
-- fixed tree, and there are finitely many subtrees reachable by deletion.
pruneTree :: Dataset -> Tree -> Tree
pruneTree dataset tree = go [] (minimumBy compareTrees [tree, simplifyTree tree])
  where
    -- Ranking: maximise accuracy, then minimise height, then node count.
    compareTrees = compare `on` (\t -> (1 - getAcc dataset t, getHeight t, getNodeCount t))
    go path t = case replaceWithSubtrees path t of
      [] -> iterateNext t path -- nothing to delete here
      subtrees ->
        let bestSubtree = minimumBy compareTrees subtrees
         in case compareTrees t bestSubtree of
              LT -> iterateNext t path -- t is better
              _ -> go path bestSubtree -- t is not better: take the deletion
    -- Move to the next position, or stop if we have walked the whole tree.
    iterateNext t path = case nextPath t path of
      Nothing -> t -- all done!
      Just newPath -> go newPath t

-- | The next position in the pre-order walk, or 'Nothing' past the end.
--
-- Descends into lambda bodies rather than skipping them (a lambda literal
-- is a leaf syntactically, but its body can still be pruned).
nextPath :: Tree -> TreePath -> Maybe TreePath
nextPath
  Leaf {_terminal = (Literal (LambdaLit (MkTypedTree lbda _)))}
  path =
    nextPath lbda path
nextPath Leaf {} _ = Nothing
nextPath Node {} [] = Just [0] -- start of the walk
nextPath n@Node {} (i : is)
  | Just x <- nextPath (_args n !! i) is = Just (i : x) -- still deeper below i
  | nextArg < length (_args n) = Just [nextArg] -- descend into the next sibling
  | otherwise = Nothing -- all children of this node exhausted
  where
    nextArg = i + 1

-- | All trees obtainable from the given position by deleting exactly one
-- wrapper node (i.e. promoting one of its children into its place).
--
-- At the root position this returns every /direct/ child promoted - but
-- only those that would still type-check: 'checkPromotableArgs' keeps the
-- arguments whose type equals the operation's output type, so replacing
-- @op xs@ by @x_i@ is only offered when @x_i@ has the same type as the
-- whole expression.
replaceWithSubtrees :: TreePath -> Tree -> [Tree]
-- custom case made for map, which fails on checkPromotableArgs
-- In a->b, we can have a==b, and then the list would be promotable
replaceWithSubtrees path l@Leaf {_terminal = (Literal (LambdaLit (MkTypedTree lbda ft)))} = (`lambdaLitT` ft) <$> replaceWithSubtrees path lbda
replaceWithSubtrees [] (Node m Map [LeafLit (LambdaLit (MkTypedTree _ (MkFunctionType [a] b))), list])
  | a == b = [list]
replaceWithSubtrees [] (Node m op trs) = (trs !!) <$> checkPromotableArgs op
replaceWithSubtrees (p : ps) node@Node {} = map (setArgAt node p) $ replaceWithSubtrees ps $ _args node !! p
replaceWithSubtrees _ _ = []

-- | Checks which args are promotable, without instantiating the polymorphic function
--
-- An argument is promotable when its declared type equals the operation's
-- declared output type: swapping it in cannot change the expression's type.
-- For polymorphic operations both sides may be type variables, and equality
-- of the variables (rather than a unification) is the conservative test
-- used here.
checkPromotableArgs :: Operation -> [Int]
checkPromotableArgs (opType -> fType) = map fst $ filter ((_outType fType ==) . snd) $ zip [0 ..] $ _argTypes fType

-- | Replaces the child at @argIndex@ (a no-op if the index is out of
-- range), used to splice a promoted subtree back into its parent.
setArgAt :: Tree -> Int -> Tree -> Tree
setArgAt node@Node {} argIndex newChild = node {_args = setAt argIndex newChild $ _args node}
setArgAt x _ _ = x

-- | Replace the element at index @i@; out-of-range indexes leave the list
-- unchanged.
setAt :: Int -> a -> [a] -> [a]
setAt i a = go i
  where
    go 0 (_ : xs) = a : xs
    go n (x : xs) = x : go (n -1) xs
    go _ [] = []
