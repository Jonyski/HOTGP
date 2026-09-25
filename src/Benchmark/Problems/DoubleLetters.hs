-- |
-- Module      : Benchmark.Problems.DoubleLetters
-- Description : Double every letter of a string.
--
-- Given a string, produce a string in which every letter appears twice,
-- the character '!' has been expanded to "!!!", and every other
-- character - spaces, digits, other punctuation, tabs, newlines - has
-- been left exactly as it was.
--
-- 'levenshteinDistance' grades it: the output has the same length as the
-- input, so a program that doubles most letters but misses a few is only
-- a few edits away from correct instead of being flatly wrong.
module Benchmark.Problems.DoubleLetters where

import Benchmark.Core
import Benchmark.Helpers
import Benchmark.Metrics (levenshteinDistance)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Grammar

-- | The benchmark: double every letter of the input string.
doubleLetters :: Benchmark (Sum Integer)
doubleLetters =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "double-letters",
      _inputTypes = [GList GChar],
      _outputType = GList GChar,
      _fitnessMetric = levenshteinDistance,
      _testCases = 1000,
      _trainCases = 100,
      _relevantTypes = S.fromList $ allowUnaryLambdas [GChar, GList GChar, GList (GList GChar), GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          -- The one character with a rule of its own: '!' becomes "!!!".
          [ (GChar, [pure $ CharLit '!'])
          ]
    }
