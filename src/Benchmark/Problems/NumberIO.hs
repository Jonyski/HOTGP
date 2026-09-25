-- |
-- Module      : Benchmark.Problems.NumberIO
-- Description : Add a floating-point number and an integer.
--
-- Given a float and an integer (in that order), produce their sum as a
-- float - the smallest problem here that mixes two different numeric
-- input types.
--
-- 'floatError' grades it: the answer is continuous, so the absolute
-- difference between expected and produced value measures how far off
-- the program is, with no artificial all-or-nothing boundary.
module Benchmark.Problems.NumberIO (numberIO) where

import Benchmark.Core (Benchmark (..))
import Benchmark.Metrics (floatError)
import qualified Data.Map as M
import Data.Monoid (Sum)
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: add the float input to the integer input.
numberIO :: Benchmark (Sum Float)
numberIO =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "number-io",
      _inputTypes = [GFloat, GInt],
      _outputType = GFloat,
      _fitnessMetric = floatError,
      _testCases = 1000,
      _trainCases = 250,
      _relevantTypes = S.fromList [GFloat, GInt],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [ (GFloat, [FloatLit <$> randomR (-100, 100)]),
            (GInt, [IntLit <$> randomR (-100, 100)])
          ]
    }
