-- |
-- Module      : Benchmark.Problems.NegativeToZero
-- Description : Clamp every negative element of a list to zero.
--
-- Given a list of integers, produce a list of the same length in which
-- every negative element has become 0 and every other element is
-- unchanged: [-3,5,0,-1] becomes [0,5,0,0].
--
-- 'levenshteinDistance' grades the list itself: each element it has to
-- insert, delete or replace costs 1, so a program that clamps most of
-- the list correctly earns partial credit instead of losing the whole
-- case.
module Benchmark.Problems.NegativeToZero where

import Benchmark.Core
import Benchmark.Helpers (allowList, allowUnaryLambdas)
import Benchmark.Metrics (levenshteinDistance)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Grammar

-- | The benchmark: replace every negative element with 0.
negativeToZero :: Benchmark (Sum Integer)
negativeToZero =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "negative-to-zero",
      _inputTypes = [GList GInt],
      _outputType = GList GInt,
      _fitnessMetric = levenshteinDistance,
      _testCases = 2000,
      _trainCases = 200,
      -- allowUnaryLambdas: the natural solution is map with a unary
      -- clamp function, so t -> t lambda types must be in the slice.
      _relevantTypes = S.fromList $ (allowUnaryLambdas <> allowList) [GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          -- The value that negatives are replaced with.
          [(GInt, [pure $ IntLit 0])]
    }
