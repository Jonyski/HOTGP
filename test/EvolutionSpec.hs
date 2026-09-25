-- |
-- Module      : EvolutionSpec
-- Description : Aggregator for the operator-level specs.
--
-- Groups the four suites that test the search's moving parts in isolation:
-- subtree selection ('EvolutionSpec.AtPointSpec'), type-safe crossover
-- ('EvolutionSpec.CrossoverSpec'), type-correct tree generation
-- ('EvolutionSpec.GenerateSpec') and mutation
-- ('EvolutionSpec.MutationSpec').
module EvolutionSpec where

import qualified EvolutionSpec.AtPointSpec
import qualified EvolutionSpec.CrossoverSpec
import qualified EvolutionSpec.GenerateSpec
import qualified EvolutionSpec.MutationSpec
import Test.Tasty

-- | The four sub-groups, exposed under \"Evolution\" by "Spec".
tests :: [TestTree]
tests =
  [ testGroup
      "Crossover"
      EvolutionSpec.CrossoverSpec.tests,
    testGroup
      "Generate - Type Check"
      EvolutionSpec.GenerateSpec.tests,
    testGroup
      "Mutation"
      EvolutionSpec.MutationSpec.tests,
    testGroup "At Point" EvolutionSpec.AtPointSpec.tests
  ]
