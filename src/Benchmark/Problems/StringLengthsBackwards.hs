-- |
-- Module      : Benchmark.Problems.StringLengthsBackwards
-- Description : The lengths of a list of strings, reversed.
--
-- Given a list of strings, produce the length of each of them written in
-- reverse order, one per line: ["abc","hi there"] becomes "8\n3", and an
-- empty input gives the empty string.
--
-- 'levenshteinDistance' grades the text, so a program that computes the
-- lengths but forgets to reverse them (or joins them wrongly) pays only
-- for the characters it has to move or change.
module Benchmark.Problems.StringLengthsBackwards (stringLengthsBackwards) where

import Benchmark.Core
import Benchmark.Helpers
import Benchmark.Metrics (levenshteinDistance)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: the lengths of the input strings, reversed.
stringLengthsBackwards :: Benchmark (Sum Integer)
stringLengthsBackwards =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "string-lengths-backwards",
      _inputTypes = [GList (GList GChar)],
      _outputType = GList GChar,
      _fitnessMetric = levenshteinDistance,
      _testCases = 1000,
      _trainCases = 100,
      -- Lists (the input, and the mapped list of lengths) plus unary
      -- lambdas, because the two steps are a map and a reverse.
      _relevantTypes = S.fromList $ (allowUnaryLambdas <> allowList) baseTypes,
      _customOutputParser = Nothing,
      _allowedConstants = M.fromList [(GInt, [intRng])]
    }
  where
    baseTypes = [GInt, GBool, GList GChar]
    intRng = IntLit <$> randomR (-100, 100)
