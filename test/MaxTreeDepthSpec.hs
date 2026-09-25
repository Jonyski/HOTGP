-- |
-- Module      : MaxTreeDepthSpec
-- Description : Run real evolution and assert the depth limit is honoured.
--
-- The other specs reason about single trees; this one runs the whole loop
-- ('Evolution.runEvolution') on a tiny config and checks the invariant the
-- config promises: no individual ever exceeds @_maxTreeDepth@.
--
-- A config is built by hand (rather than from a benchmark) so the test is
-- fast and hermetic: a small population, 50 evaluations, no dataset, and a
-- constant fitness - the property is about /structure/, not search quality.
-- The sampler tables ('buildTable') are still built for real, so generation
-- and mutation are exercised.
module MaxTreeDepthSpec where

import Benchmark.BenchmarkToConfig (operationsFromTypes)
import Benchmark.Helpers
import Control.Monad.State.Strict (evalState)
import qualified Data.Foldable as S
import Data.List (nub)
import qualified Data.Map as M
import Data.Maybe (maybeToList)
import qualified Data.SortedList as SL
import Evolution
import EvolutionSpec.Helpers
import Grammar (FunctionType (_argTypes), ProgramType, Terminal, getHeight)
import Grammar.Core
import Test.Tasty
import qualified Test.Tasty.QuickCheck as QC

-- | One property, run 10 times per test run (it is comparatively expensive).
tests :: [TestTree]
tests =
  [ QC.testProperty "Evolution never exceeds max tree depth" $ QC.withMaxSuccess 10 testMaxTreeDepth
  ]

-- | A minimal, constant-fitness 'Config' with a fixed depth limit.
--
-- The term/operation tables are deliberately /rich/ (pairs, lists, unary
-- lambdas) so that generation has every opportunity to overshoot - the
-- property is only interesting if a buggy generator would be caught.
createTestConfig :: Depth -> ProgramType -> Config Int
createTestConfig depth pgType =
  MkConfig
    { _programType = pgType,
      _maxTreeDepth = depth,
      _maxMutationTreeDepth = depth,
      _maxInitialDepth = depth,
      _popSize = 10,
      _individualsPerStep = 2,
      _nEvaluations = 50,
      _fitnessFunction = const 1,
      _parentScalar = 0.98,
      _crossoverRate = 0.5,
      _fullTable = buildTable termsAndOps depth True,
      _growTable = buildTable termsAndOps depth False
    }
  where
    termsAndOps :: TermsAndOps
    termsAndOps =
      MkTermsAndOps
        { _literals =
            M.fromList
              [ (GInt, mkTerm $ IntLit 42),
                (GFloat, mkTerm $ FloatLit 42.0),
                (GChar, mkTerm $ CharLit 'm'),
                (GBool, mkTerm $ BoolLit True)
              ],
          _arguments = M.empty,
          _operations = operationsFromTypes $ allowUnaryLambdas types <> allowList types
        }
    types = allowPairs [GInt, GBool, GChar, GFloat]
    mkTerm lit = [return lit]

-- | Property body: pick a random program type and a limit of 3-5, run a
-- full evolution, then conjoin \"height <= limit\" over every tree that was
-- ever in the population. The label records the largest height seen, so the
-- QuickCheck output shows the distribution of sizes actually reached.
testMaxTreeDepth :: QC.Gen QC.Property
testMaxTreeDepth = do
  fType <- QC.arbitrary
  maxDepth <- QC.chooseInt (3, 5)
  let cfg = createTestConfig maxDepth fType
  list <- map _indTree . SL.fromSortedList <$> withRandomSeed (runEvolution cfg)
  let depths = getHeight <$> list
  return $ QC.label (show (maximum depths) <> " <= " <> show maxDepth) $ QC.conjoin $ (<= maxDepth) <$> depths
