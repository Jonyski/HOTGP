-- |
-- Module      : Benchmark.Problems.MirrorImage
-- Description : Do two lists mirror each other?
--
-- Given two lists of the same length, produce True exactly when the
-- second list is the reverse of the first, i.e. when the two are mirror
-- images of one another; otherwise False. The upstream cases always
-- arrive with equal lengths.
--
-- 'boolError' grades it: it is a yes/no question, so a wrong answer
-- costs 1 and there is no partial credit to hand out.
module Benchmark.Problems.MirrorImage where

import Benchmark.Core
import Benchmark.Helpers (allowList, allowPairs, allowUnaryLambdas)
import Benchmark.Metrics (boolError)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: are the two lists mirror images of each other?
mirrorImage :: Benchmark (Sum Integer)
mirrorImage =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "mirror-image",
      _inputTypes = [GList GInt, GList GInt],
      _outputType = GBool,
      _fitnessMetric = boolError,
      _testCases = 1000,
      _trainCases = 100,
      -- Pairs because the check zips one list against the reversed other
      -- one and compares the two halves of each pair; lists and lambdas
      -- supply reverse/filter.
      _relevantTypes = S.fromList $ (allowUnaryLambdas <> allowList) $ allowPairs [GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [(GBool, pure . BoolLit <$> [True, False])]
    }
