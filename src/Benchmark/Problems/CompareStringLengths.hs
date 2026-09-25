-- |
-- Module      : Benchmark.Problems.CompareStringLengths
-- Description : Are three strings strictly increasing in length?
--
-- Given three strings, produce True exactly when the first is shorter
-- than the second and the second is shorter than the third; equal
-- lengths (including three empty strings) give False.
--
-- 'boolError' grades it: the answer is yes-or-no, so a mistake costs 1
-- and there is nothing in between that a partially correct program could
-- be rewarded for.
module Benchmark.Problems.CompareStringLengths (compareStringLengths) where

import Benchmark.Core
import Benchmark.Helpers
import Benchmark.Metrics (boolError)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: are the three strings strictly increasing in length?
compareStringLengths :: Benchmark (Sum Integer)
compareStringLengths =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "compare-string-lengths",
      _inputTypes = [GList GChar, GList GChar, GList GChar],
      _outputType = GBool,
      _fitnessMetric = boolError,
      _testCases = 1000,
      _trainCases = 100,
      -- Ints matter here only because 'length' produces them: without
      -- GInt in the slice the comparisons of lengths cannot be written.
      _relevantTypes = S.fromList [GInt, GBool, GList GChar],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [ (GBool, return . BoolLit <$> [True, False])
          ]
    }
