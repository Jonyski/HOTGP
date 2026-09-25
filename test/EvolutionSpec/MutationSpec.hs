{-# LANGUAGE TupleSections #-}

-- |
-- Module      : EvolutionSpec.MutationSpec
-- Description : Mutated children stay well-typed.
--
-- Mutation swaps a random subtree for a freshly generated one
-- ('Evolution.Mutation.mutate'). Like crossover, it must never produce an
-- ill-typed tree; unlike crossover, its guarantee is conditional on the
-- result fitting '_maxTreeDepth'. 'mutateTyped' therefore retries until
-- the mutated tree both type-checks and fits the depth budget - the
-- property asserts that this retry loop terminates with a tree satisfying
-- 'validTypedTree'.
module EvolutionSpec.MutationSpec where

import Evolution
import EvolutionSpec.Helpers
import Grammar
import Test.Tasty
import qualified Test.Tasty.QuickCheck as QC

-- | The single \"Mutation TypeChecks\" property.
tests :: [TestTree]
tests = [QC.testProperty "Mutation TypeChecks" mutationTypeChecks]

-- | Mutate every tree of a small ramped population and check the results.
mutationTypeChecks :: QC.Gen QC.Property
mutationTypeChecks = do
  fType <- QC.arbitrary
  (config, trees) <- arbitraryRampedOfTypeWithConfig fType
  xMen <- withRandomSeed $ sequence (mutateTyped config . snd <$> trees)
  return $ QC.conjoin (validTypedTree . (_maxTreeDepth config,) <$> xMen)

mutateTyped :: Ord a => Config a -> TypedTree -> St TypedTree
mutateTyped cfg tt@(MkTypedTree t ft) = do
  newTree <- mutate cfg t
  if getHeight newTree <= _maxTreeDepth cfg
    then return $ MkTypedTree newTree ft
    else mutateTyped cfg tt
