-- |
-- Module      : Benchmark.Problems.LastIndexOfZero
-- Description : Where a list contains its last zero.
--
-- Given a list of integers, produce the 0-based index of the last
-- element that equals 0 - for [7,0,3,0,1] that is 4. The upstream cases
-- always contain at least one zero, so the answer is always defined.
--
-- 'intError' grades it: the answer is a single index, and being k
-- positions off costs k, which rewards a program that finds *a* zero
-- even when it is not the last one.
module Benchmark.Problems.LastIndexOfZero (lastIndexOfZero) where

import Benchmark.Core
import Benchmark.Helpers
  ( allowList,
    allowPairs,
    allowUnaryLambdas,
  )
import Benchmark.Metrics (intError)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: the 0-based index of the last zero in a list.
lastIndexOfZero :: Benchmark (Sum Integer)
lastIndexOfZero =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "last-index-of-zero",
      _inputTypes = [GList GInt],
      _outputType = GInt,
      _fitnessMetric = intError,
      _testCases = 1000,
      _trainCases = 150,
      -- Pairs are the point of this slice: zipping the list with
      -- [0..length-1] pairs every element with its index, which a filter
      -- over pairs can then reduce to the last zero's position.
      _relevantTypes = S.fromList $ (allowUnaryLambdas <> allowList) $ allowPairs [GBool, GInt],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          -- The value being searched for.
          [(GInt, [return $ IntLit 0])]
    }
