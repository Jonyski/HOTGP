-- |
-- Module      : Benchmark.Problems.Syllables
-- Description : Count a string's vowels and announce the total.
--
-- Given a string, produce the sentence "The number of syllables is N",
-- where N is how many of its characters are vowels - the crude syllable
-- estimate of the original benchmark, in which a, e, i, o, u and y all
-- count while consonants, digits, spaces and punctuation do not ("quite"
-- has 3).
--
-- 'levenshteinDistance' grades the sentence: a program that gets the
-- wording right but the count wrong is only a few edits from the
-- expected answer, which keeps the search moving in the right direction.
module Benchmark.Problems.Syllables (syllables) where

import Benchmark.Core (Benchmark (..))
import Benchmark.Helpers
import Benchmark.Metrics
import Control.Monad
import Data.Align (alignWith)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR, sample)
import Evolution.Core (St)
import Grammar

-- | The benchmark: announce how many vowels the input string contains.
syllables :: Benchmark (Sum Integer)
syllables =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "syllables",
      _inputTypes = [GList GChar],
      _outputType = GList GChar,
      _fitnessMetric = levenshteinDistance,
      _testCases = 2000,
      _trainCases = 200,
      _relevantTypes = S.fromList $ allowUnaryLambdas [GList GChar, GChar, GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          -- A random score-shaped ERC; the real count comes from the
          -- program, not from a constant.
          [ (GInt, [IntLit <$> randomR (0, 100)]),
            ( GList GChar,
              -- The prefix of the answer sentence, the vowel string
              -- itself (handy for counting), and a random string ERC.
              ( pure . stLit
                  <$> [ "The number of syllables is ",
                        vowels
                      ]
              )
                <> [stLit <$> stringErc]
            ),
            (GChar, (pure . CharLit <$> vowels) <> [CharLit <$> randomR ('!', '~')])
          ]
    }

-- | The characters counted as vowels: the five usual ones plus y,
-- matching how the expected counts in the dataset were produced.
vowels :: [Char]
vowels = "aeiouy"

-- | Everything that is not a vowel - the remaining lowercase letters
-- plus digits and a space: the pool 'stringErc' draws from.
nonVowels :: [Char]
nonVowels = filter (`notElem` vowels) ['a' .. 'z'] <> " 123456789"

-- | A random string constant (an ERC) of length 0-20, about 20% of
-- whose characters are vowels and the rest drawn from 'nonVowels'. It
-- gives the search example-shaped string literals to reuse and mutate.
stringErc :: St String
stringErc = do
  len <- randomR (0, 20 :: Int)
  replicateM len $ do
    isVowel <- (< 0.2) <$> randomR (0, 1.0 :: Float)
    sample $ if isVowel then vowels else nonVowels
