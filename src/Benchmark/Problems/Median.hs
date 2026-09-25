-- |
-- Module      : Benchmark.Problems.Median
-- Description : The middle value of three integers.
--
-- Given three integers, produce the one that lies between the other two
-- - the median of the three, whichever order they arrive in.
--
-- 'rightWrong' grades it, the strictest metric available: the answer is
-- an exact integer, so a program scores 0 for the right value and 1 for
-- anything else, with no credit at all for being close.
module Benchmark.Problems.Median where

import Benchmark.Core
import Benchmark.Metrics (rightWrong)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: the median of three integers.
median :: Benchmark (Sum Integer)
median =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "median",
      _inputTypes = [GInt, GInt, GInt],
      _outputType = GInt,
      _fitnessMetric = rightWrong,
      _testCases = 1000,
      _trainCases = 100,
      -- Only ints and the booleans that comparing them produces: no
      -- lists, pairs or lambdas are needed for three scalar arguments.
      _relevantTypes = S.fromList [GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [(GInt, [IntLit <$> randomR (-100, 100)])]
    }
