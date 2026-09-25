-- |
-- Module      : Benchmark.Problems.Smallest
-- Description : The smallest of four integers.
--
-- Given four integers, produce the smallest of them (equal values are
-- fine: if every argument is -22 the answer is -22).
--
-- 'rightWrong' grades it, the strictest metric: the answer is a single
-- exact integer, so a program scores 0 only when it names the minimum
-- and 1 otherwise, with no partial credit.
module Benchmark.Problems.Smallest where

import Benchmark.Core
import Benchmark.Metrics (rightWrong)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR, sample)
import Grammar

-- | The benchmark: the smallest of four integers.
smallest :: Benchmark (Sum Integer)
smallest =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "smallest",
      _inputTypes = [GInt, GInt, GInt, GInt],
      _outputType = GInt,
      _fitnessMetric = rightWrong,
      _testCases = 1000,
      _trainCases = 100,
      _relevantTypes = S.fromList [GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [(GInt, [intRng])]
    }
  where
    intRng = IntLit <$> randomR (-100, 100)
