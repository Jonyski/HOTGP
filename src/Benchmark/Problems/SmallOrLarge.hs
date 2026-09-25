{-# LANGUAGE NumericUnderscores #-}

-- |
-- Module      : Benchmark.Problems.SmallOrLarge
-- Description : Label an integer as small, large or neither.
--
-- Given one integer, produce "small" when it is below 1000, the empty
-- string when it lies between 1000 (inclusive) and 2000 (exclusive),
-- and "large" when it reaches 2000 - those three strings are exactly
-- what the dataset holds as expected outputs.
--
-- 'levenshteinDistance' grades the answer: it is a very short string,
-- so a program that outputs a close-but-wrong word pays only for the
-- characters that differ rather than losing the case outright.
module Benchmark.Problems.SmallOrLarge where

import Benchmark.Core
import Benchmark.Helpers
  ( allowList,
    allowPairs,
  )
import Benchmark.Metrics (levenshteinDistance)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR, sample)
import Grammar

-- | The benchmark: label an integer "small", "large" or neither.
smallOrLarge :: Benchmark (Sum Integer)
smallOrLarge =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "small-or-large",
      _inputTypes = [GInt],
      _outputType = GList GChar,
      _fitnessMetric = levenshteinDistance,
      _testCases = 1000,
      _trainCases = 100,
      -- Only scalars and the answer type: thresholds are compared, the
      -- verdict is a string. No lists or lambdas are needed.
      _relevantTypes = S.fromList [GInt, GBool, GList GChar],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          -- A random integer ERC spanning the range the inputs use.
          [ (GInt, [intRng]),
            -- The two non-empty verdicts as literals; the middle case is
            -- the empty string, for which there is no constant here.
            (GList GChar, pure . stLit <$> ["small", "large"])
          ]
    }
  where
    intRng = IntLit <$> randomR (-10_000, 10_000)
