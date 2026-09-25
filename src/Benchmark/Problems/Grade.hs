-- |
-- Module      : Benchmark.Problems.Grade
-- Description : Five integers in, a letter-grade sentence out.
--
-- Given five integers - four grade cutoffs in descending order, then the
-- student's score - produce the sentence "Student has a X grade.", where
-- X is A when the score reaches the first cutoff, B for the second, C
-- for the third, D for the fourth and F when it reaches none of them.
--
-- 'levenshteinDistance' grades the sentence: the answer is text, so a
-- program with the right wording but the wrong letter (or the wrong
-- wording but the right letter) pays only for the characters that differ.
module Benchmark.Problems.Grade (grade) where

import Benchmark.Core (Benchmark (..))
import Benchmark.Helpers
import Benchmark.Metrics
import Data.Align (alignWith)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: turn four cutoffs and a score into a grade sentence.
grade :: Benchmark (Sum Integer)
grade =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "grade",
      _inputTypes = replicate 5 GInt,
      _outputType = GList GChar,
      _fitnessMetric = levenshteinDistance,
      _testCases = 2000,
      _trainCases = 200,
      -- A list of strings as well, so the sentence can be assembled from
      -- its pieces and concatenated into one string.
      _relevantTypes = S.fromList [GList (GList GChar), GList GChar, GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          -- A random score-shaped ERC; the real cutoffs arrive as inputs.
          [ (GInt, [IntLit <$> randomR (0, 100)]),
            -- Exactly the pieces the answer is built from: the two
            -- fragments of the sentence and the five possible letters.
            ( GList GChar,
              pure . stLit
                <$> [ "Student has a ",
                      " grade.",
                      "A",
                      "B",
                      "C",
                      "D",
                      "F"
                    ]
            )
          ]
    }
