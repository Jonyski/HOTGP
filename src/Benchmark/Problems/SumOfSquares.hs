-- |
-- Module      : Benchmark.Problems.SumOfSquares
-- Description : The sum of the squares from 1 up to n.
--
-- Given a positive integer n, produce 1^2 + 2^2 + ... + n^2; n = 5 gives
-- 55 and n = 100 gives 338350.
--
-- 'intError' grades it: the answers grow quickly, so the absolute
-- difference still separates near misses from far ones - a program that
-- stops the sum one term early is only off by the square it skipped.
module Benchmark.Problems.SumOfSquares where

import Benchmark.Core
import Benchmark.Helpers (allowList, allowUnaryLambdas)
import Benchmark.Metrics (intError)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: 1^2 + 2^2 + ... + n^2.
sumOfSquares :: Benchmark (Sum Integer)
sumOfSquares =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "sum-of-squares",
      _inputTypes = [GInt],
      _outputType = GInt,
      _fitnessMetric = intError,
      -- Unusually small and even: the upstream dataset only holds about
      -- a hundred cases in total, so there is no large test half to take.
      _testCases = 50,
      _trainCases = 50,
      _relevantTypes = S.fromList $ (allowUnaryLambdas <> allowList) [GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants = M.fromList [(GInt, [intRng, pure $ IntLit 0, pure $ IntLit 1])]
    }
  where
    intRng = IntLit <$> randomR (-100, 100)