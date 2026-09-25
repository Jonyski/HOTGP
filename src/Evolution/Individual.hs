{-# LANGUAGE GADTs #-}
{-# LANGUAGE StandaloneDeriving #-}

-- |
-- Module      : Evolution.Individual
-- Description : A program paired with its fitness, and the population type.
--
-- An 'Individual' is one candidate solution: the program ('Tree') plus the
-- score it earned. Keeping them together means the population never has to
-- re-evaluate a tree it has already seen.
--
-- The population itself is a 'SortedPop' - a list kept sorted by the 'Ord'
-- instance below - so \"best individual\" is always just the head, and
-- truncating to the top N is a cheap take.

module Evolution.Individual where

import qualified Data.SortedList as SL
import Evolution.Config
import Evolution.Fitness
import Grammar

-- | A candidate program together with its already-computed fitness.
--
-- The GADT carries the @Fitness a@ constraint so that instances (Show, Read,
-- Ord) can be derived on demand where they are needed.
data Individual a where
  MkIndividual :: (Fitness a) => {_indTree :: !Tree, _fitness :: a} -> Individual a

-- | A population kept in sorted order (best first, per 'Ord' below).
--
-- 'Data.SortedList.SortedList' is an abstract type that maintains the
-- invariant, so callers cannot accidentally unsort it.
type SortedPop a = SL.SortedList (Individual a)

deriving instance Fitness a => Show (Individual a)

deriving instance Fitness a => Read (Individual a)

-- | Structural equality: two individuals are equal iff their programs are.
-- Fitness is deliberately ignored - it is a pure function of the tree, so
-- comparing it as well would be redundant (and would break for fitnesses
-- that round differently).
instance Eq (Individual a) where
  i1 == i2 = _indTree i1 == _indTree i2

-- | Ranking order: lower fitness is better (all fitness types follow the
-- \"smaller is better\" convention - see "Evolution.Fitness").
--
-- The tie-breaker matters: when two programs score identically, the
-- /smaller/ one wins. This is parsimony pressure - it keeps the search from
-- preferring bloated programs when a compact one does the same job.
instance (Ord a) => Ord (Individual a) where
  compare i1 i2 = case compare (_fitness i1) (_fitness i2) of
    EQ -> compare (getNodeCount $ _indTree i1) (getNodeCount $ _indTree i2)
    x -> x

-- | The best individual in a population (the head of the sorted list).
--
-- Partial: an empty population has no best individual, which would be a bug
-- in the caller (the run loop always keeps the population at _popSize).
bestIndividual :: SortedPop a -> Individual a
bestIndividual = head . SL.fromSortedList

-- | Scores a tree with the config's fitness function.
--
-- Also calls 'computeMeasure' first, so the stored tree always carries a
-- valid measure cache - everything downstream (depth checks, tie-breaking,
-- logging) can rely on it.
mkIndividual :: (Fitness a) => Config a -> Tree -> Individual a
mkIndividual config tree = MkIndividual computedTree (_fitnessFunction config computedTree)
  where
    computedTree = computeMeasure tree
