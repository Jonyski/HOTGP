-- |
-- Module      : Benchmark.Problems.ForLoopIndex
-- Description : The index sequence a classic for loop would visit.
--
-- Given three integers - a start, an exclusive end and a step - produce
-- the values start, start+step, start+2*step, ... for as long as they
-- stay below the end, written one per line: exactly what
-- @for (i = start; i < end; i += step)@ visits, printed as text.
--
-- 'levenshteinDistance' grades the string: a program that builds the
-- sequence correctly but joins it wrongly, or is off by one line, pays
-- only for the characters it added, dropped or changed.
module Benchmark.Problems.ForLoopIndex (forLoopIndex) where

import Benchmark.Core
import Benchmark.Helpers
import Benchmark.Metrics (levenshteinDistance)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: the index sequence a for loop with these three
-- bounds would visit, printed one value per line.
forLoopIndex :: Benchmark (Sum Integer)
forLoopIndex =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "for-loop-index",
      _inputTypes = [GInt, GInt, GInt],
      _outputType = GList GChar,
      _fitnessMetric = levenshteinDistance,
      _testCases = 1000,
      _trainCases = 100,
      -- range produces a list, showInt renders one element and unlines
      -- joins them, so lists, chars and unary lambdas are all needed;
      -- ints are the loop variables themselves.
      _relevantTypes = S.fromList $ (allowUnaryLambdas <> allowList) [GInt, GChar, GList GChar],
      _customOutputParser = Nothing,
      _allowedConstants = M.empty
    }
