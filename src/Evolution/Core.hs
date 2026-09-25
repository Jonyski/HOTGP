-- |
-- Module      : Evolution.Core
-- Description : Shared type aliases for the evolutionary algorithm.
--
-- This module is deliberately tiny: it only names the concepts the rest of
-- the Evolution layer passes around, so that signatures read like the
-- textbook algorithm rather than like plumbing.
module Evolution.Core where

import qualified Control.Monad.State.Strict as S
import Grammar.Core (Tree)
import qualified System.Random as R

-- | A position inside a tree, expressed as the 1-based index of a node in a
-- pre-order (depth-first, left-to-right) traversal.
--
-- @atPoint@, @getBranchAt@ and the crossover all address subtrees this way:
-- it gives a single integer that identifies any node, which is convenient
-- for picking a random mutation/crossover point.
type Point = Int

-- | The state threaded through every stochastic computation: a random number
-- generator.
--
-- Keeping the generator in a 'S.State' monad (instead of using global IO
-- randomness) is what makes whole runs reproducible from a single seed - the
-- benchmark results in the log files can be re-run exactly.
type St a = S.State R.StdGen a

-- | Tree depth, in nodes (root = 0 or 1 depending on the caller's
-- convention; the limits in "Evolution.Config" are measured the same way as
-- 'Grammar.Helpers.getCurrentDepth').
type Depth = Int

-- | Number of individuals in the population.
type PopSize = Int

-- | A genetic operator: a stateful transformation of one tree into another.
--
-- All mutations have this shape so they can be applied with @mapM (mutate cfg)@
-- and threaded through 'St' without extra ceremony.
type Mutation = Tree -> St Tree
