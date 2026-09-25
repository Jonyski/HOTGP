-- |
-- Module      : EvolutionSpec.Helpers
-- Description : Fixtures shared by the Evolution specs.
--
-- Everything the operator specs need in order to run the /real/ code on
-- controlled inputs:
--
-- * 'makeTestConfig' - a 'Config' built from a throwaway 'Benchmark', so
--   sampler tables can be built without a dataset or network access;
-- * 'withRandomSeed' - run an 'St' (state + RNG) computation under a
--   QuickCheck-chosen seed, making runs reproducible;
-- * an 'Arbitrary' instance for 'FunctionType' (random argument and result
--   types, drawn from 'Helpers.arbitraryType');
-- * generators for single trees ('arbitraryTree') and whole ramped
--   populations ('arbitraryRamped');
-- * the assertion helpers 'runTypeCheck', 'testMaxDepth' and
--   'validTypedTree' used throughout the specs.
module EvolutionSpec.Helpers where

import Benchmark
import Benchmark.BenchmarkToConfig
import Benchmark.Core
import Benchmark.Helpers
import qualified Control.Monad.State.Strict as S
import qualified Data.Map as M
import Data.Maybe (catMaybes, isJust)
import qualified Data.Set as S
import Evolution
import Grammar
import Helpers
import Pretty
import qualified System.Random as R
import Test.QuickCheck.Gen (unGen)
import Test.QuickCheck.Random (mkQCGen)
import qualified Test.Tasty.QuickCheck as QC

-- | A 'Config' for @fType@ with a fixed depth limit and a tiny evaluation
-- budget, built on top of a dummy benchmark.
--
-- The benchmark supplies the things 'makeConfig' derives from a problem -
-- relevant types and allowed constants (42, 42.0, 'm', True) - while the
-- fields that only matter during a real run (dataset, fitness metric) are
-- left as @undefined@ and never forced.
makeTestConfig :: FunctionType -> Depth -> Int -> Config Int
makeTestConfig fType maxDepth sz = update $ makeConfig undefined bench
  where
    update :: Config (Result ()) -> Config Int
    update config =
      MkConfig
        { _programType = fType,
          _fullTable = _fullTable config,
          _growTable = _growTable config,
          _maxTreeDepth = maxDepth,
          _maxMutationTreeDepth = maxDepth,
          _maxInitialDepth = maxDepth,
          _popSize = sz,
          _individualsPerStep = 3,
          _nEvaluations = 3,
          _fitnessFunction = const 3,
          _parentScalar = _parentScalar config,
          _crossoverRate = _crossoverRate config
        }
    bench :: Benchmark ()
    bench =
      MkBenchmark
        { _benchmarkId = Nothing,
          _datasetName = "test",
          _inputTypes = _argTypes fType,
          _outputType = _outType fType,
          _fitnessMetric = undefined,
          _testCases = 0,
          _trainCases = 0,
          _relevantTypes = S.fromList $ [GInt, GFloat, GChar, GBool] <> _argTypes fType <> [_outType fType],
          _customOutputParser = Nothing,
          _allowedConstants =
            M.fromList
              [ (GInt, [return $ IntLit 42]),
                (GFloat, [return $ FloatLit 42.0]),
                (GChar, [return $ CharLit 'm']),
                (GBool, [return $ BoolLit True])
              ]
        }

-- | Run a stateful computation with a randomly chosen, but shrinking,
-- stdgen seed. QuickCheck sees a plain 'QC.Gen', so a failing case can be
-- shrunk and replayed.
withRandomSeed :: St a -> QC.Gen a
withRandomSeed stateful = S.evalState stateful . R.mkStdGen <$> QC.arbitrary

-- | Random program types: an arbitrary output type with a random list of
-- argument types (including zero arguments - nullary programs are legal).
instance QC.Arbitrary FunctionType where
  arbitrary = do
    outType <- arbitraryType
    argTypes <- QC.listOf arbitraryType
    return (argTypes ->> outType)

-- | Generate one tree at a random depth (1-10) using the given generator
-- function ('Evolution.Generate.full', @grow@, ...) under a fresh config.
arbitraryTree :: (Config Int -> Depth -> OutputType -> St Tree) -> QC.Gen (Depth, TypedTree)
arbitraryTree method = do
  depth <- QC.chooseInt (1, 10)
  fType <- QC.arbitrary
  (\t -> (depth, MkTypedTree t fType)) <$> withRandomSeed (method (makeTestConfig fType depth 10) depth (_outType fType))

-- | A ramped population for a given program type: pick a max depth in
-- 4-10, build a config sized after the current QuickCheck size parameter,
-- and generate a full initial population with 'ramped'.
arbitraryRampedOfType :: FunctionType -> QC.Gen [(Depth, TypedTree)]
arbitraryRampedOfType fType = snd <$> arbitraryRampedOfTypeWithConfig fType

-- | Like 'arbitraryRampedOfType' but also returns the config the trees
-- were generated with - the operator specs need it (depth limit, sampler
-- tables) to run crossover/mutation on exactly these trees.
arbitraryRampedOfTypeWithConfig :: FunctionType -> QC.Gen (Config Int, [(Depth, TypedTree)])
arbitraryRampedOfTypeWithConfig fType = do
  maxDepth <- QC.chooseInt (4, 10)
  size <- QC.getSize
  let cfg = makeTestConfig fType maxDepth size
  trees <- withRandomSeed $ ramped cfg
  return (cfg, (\t -> (maxDepth, MkTypedTree t fType)) <$> trees)

-- | Ramped population for a randomly chosen program type.
arbitraryRamped :: QC.Gen [(Depth, TypedTree)]
arbitraryRamped = QC.arbitrary >>= arbitraryRampedOfType

-- | Assert that a tree type-checks against its declared type; the
-- counterexample prints the offending tree and type rather than just
-- \"falsified\".
runTypeCheck :: TypedTree -> QC.Property
runTypeCheck tt = QC.counterexample ce $ isJust $ typeCheck (_type tt) (_tree tt)
  where
    ce =
      pretty (_tree tt)
        <> " does not have type "
        <> pretty (_type tt)

-- | Assert that a tree's height is at most @desiredMaxDepth@, with a
-- counterexample naming the tree, its measured height and the limit.
testMaxDepth :: Depth -> TypedTree -> QC.Property
testMaxDepth desiredMaxDepth typedTree = QC.counterexample ce (d <= desiredMaxDepth)
  where
    t = _tree typedTree
    d = getHeight t
    ce =
      "Tree `"
        <> pretty t
        <> "` has depth of "
        <> show d
        <> " but should have it at max "
        <> show desiredMaxDepth

-- | The standard \"this generated tree is acceptable\" property: it fits
-- the depth budget /and/ type-checks. Used by the generate, crossover and
-- mutation specs alike.
validTypedTree :: (Depth, TypedTree) -> QC.Property
validTypedTree (depth, tt) = testMaxDepth depth tt QC..&&. runTypeCheck tt
