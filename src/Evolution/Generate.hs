-- |
-- Module      : Evolution.Generate
-- Description : Building the initial population (full, grow, ramped).
--
-- Genetic programming needs a starting population of random programs. Two
-- classic generators, from Koza's original work, are used here:
--
-- * /full/ - every branch is grown to exactly the requested depth, so the
--   tree is bushy and every leaf is a terminal. Good for variety at the
--   leaves.
-- * /grow/ - branches may stop early and become terminals at any depth, so
--   trees come out smaller and more varied in shape.
--
-- Both delegate the actual node-by-node choices to
-- 'Evolution.SamplerTable.buildTree', which guarantees the trees are
-- well-typed by construction (an operation is only offered at a position
-- where its signature fits).
--
-- The initial population uses /ramped half-and-half/ ('ramped'): a mix of
-- both generators across a range of depths, which is the standard way to
-- avoid starting the search with an all-identical population.
module Evolution.Generate where

import Control.Monad (join, replicateM)
import qualified Data.Map as M
import Evolution.Config
import Evolution.Core (Depth, PopSize, St)
import Evolution.Helpers (sample)
import Evolution.SamplerTable (buildTree)
import Grammar (ArgTypes, FunctionType (_argTypes, _outType), Operation, OutputType, Tree (..))
import Grammar.Core

-- | Generates a tree that is of full depth along any path.
full ::
  -- | The configuration of the desired program
  Config a ->
  -- | The depth that this tree will have
  Depth ->
  -- | The type that this tree will output
  OutputType ->
  St Tree
full cfg = buildTree (_fullTable cfg)

-- | Generates a tree that might be smaller than the desired output.
grow ::
  -- | The configuration of the desired program
  Config a ->
  -- | The maximum depth that this tree will have
  Depth ->
  -- | The type that this tree will output
  OutputType ->
  St Tree
grow cfg = buildTree (_growTable cfg)

-- | "Ramped-half-and-half" generates trees of all different shapes and sizes.
-- This is Koza's standard approach to generating an initial population.
-- It uses the full method to generate half the members and the grow method to generate the other half.
--
-- How the loop works: starting at depth 2 and stepping up towards
-- _maxInitialDepth, each round is responsible for a slice of the population
-- (@n = popSize / remainingDepthRange@) and fills it with half 'full' and
-- half 'grow' trees at that depth. The remainder from the division is
-- handed to 'grow' so the population size is exact. The recursion stops
-- once the population is full.
ramped ::
  -- | The configuration of the desired program
  Config a ->
  St [Tree]
ramped cfg = go [] (_popSize cfg) 2
  where
    go :: [Tree] -> PopSize -> Depth -> St [Tree]
    go pop 0 _ = return pop
    go pop nPop minDepth = do
      treesFull <- replicateM half (full cfg minDepth outputType)
      treesGrow <- replicateM (half + r) (grow cfg minDepth outputType)
      go (treesFull <> treesGrow <> pop) (nPop - n) (minDepth + 1)
      where
        range = maxDepth - minDepth + 1
        n = nPop `div` range
        (half, r) = quotRem n 2

    -- Every tree in the initial population must produce the program's
    -- output type, otherwise it could not be a candidate solution.
    outputType :: OutputType
    outputType = _outType $ _programType cfg
    maxDepth :: Depth
    maxDepth = _maxInitialDepth cfg
