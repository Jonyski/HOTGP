-- |
-- Module      : Benchmark.Problems.Digits
-- Description : Write an integer out as one digit per line.
--
-- Given an integer, produce its decimal digits as a string with one
-- digit per line, least significant digit first; a negative number keeps
-- its minus sign on the most significant digit, so -482 becomes
-- "2\n8\n-4" and 0 stays "0".
--
-- The expected answer is text, so 'levenshteinDistance' grades it: a
-- program that writes the right digits but the wrong separators pays a
-- couple of edits instead of losing the whole case.
module Benchmark.Problems.Digits (digits) where

import Benchmark.Core (Benchmark (..))
import Benchmark.Helpers
import Benchmark.Metrics
import Data.Align (alignWith)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: write an integer out as one digit per line.
digits :: Benchmark (Sum Integer)
digits =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "digits",
      _inputTypes = [GInt],
      _outputType = GList GChar,
      _fitnessMetric = levenshteinDistance,
      _testCases = 1000,
      _trainCases = 100,
      _relevantTypes = S.fromList $ allowUnaryLambdas [GList GChar, GChar, GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [ (GInt, [IntLit <$> randomR (-10, 10)]),
            -- The newline that separates the digits: the expected output
            -- is exactly one digit per line.
            (GChar, [pure $ CharLit '\n'])
          ]
    }
