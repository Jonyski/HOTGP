-- |
-- Module      : Benchmark.Problems.StringDifferences
-- Description : Report, position by position, where two strings differ.
--
-- Given two strings, produce one entry for every position at which they
-- differ, considering only positions both strings actually have; each
-- entry holds the index and the two characters found there ("STOP" vs
-- "SIGN" gives the three entries 1 T I, 2 O G and 3 P N). The dataset
-- stores that as one "@index c1 c2@" line per difference, which
-- 'parseOutput' turns back into a list of pairs.
--
-- 'wrongCases' grades the list: a position present on both sides costs
-- 1 for each of its three fields that disagree, while a whole line that
-- is missing from - or extra in - the answer costs the full 3.
module Benchmark.Problems.StringDifferences (stringDifferences) where

import Benchmark.Core
import Benchmark.Helpers
import Benchmark.Parse (OutputParser, parseJsonLit, (^.))
import Data.Aeson (Value (String))
import Data.Align
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import qualified Data.Text as T
import Data.These
import Evolution (randomR)
import Grammar

-- | The benchmark: the list of (index, (char from first, char from
-- second)) triples for every differing position.
stringDifferences :: Benchmark (Sum Integer)
stringDifferences =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "string-differences",
      _inputTypes = [GList GChar, GList GChar],
      _outputType = GList (GPair GInt (GPair GChar GChar)),
      _fitnessMetric = wrongCases,
      _testCases = 2000,
      _trainCases = 200,
      -- The pair types are the shape of the answer itself - an index
      -- paired with a pair of characters - so the grammar must be able
      -- to build them; lists and lambdas provide zip/filter.
      _relevantTypes = S.fromList $ (allowList <> allowUnaryLambdas) baseTypes,
      -- The expected output is text (one line per difference), not a
      -- JSON array, so it needs its own parser.
      _customOutputParser = Just parseOutput,
      _allowedConstants = M.fromList [(GInt, [intRng])]
    }
  where
    baseTypes = [GInt, GBool, GChar, GPair GChar GChar, GPair GInt (GPair GChar GChar)]
    intRng = IntLit <$> randomR (-10, 10)

-- | Splits the dataset's @output1@ into lines, then each line into its
-- three whitespace-separated words: index, first character, second
-- character.
parseOutput :: OutputParser
parseOutput obj = tListLitOf (GPair GInt (GPair GChar GChar)) listToTuple (map words . lines $ T.unpack txt)
  where
    String txt = obj ^. "output1"

-- | Turns the three words of one line - @["0","B","C"]@ - into the pair
-- (0, ('B','C')) the output type expects. Partial: a line without
-- exactly three fields would mean the dataset is malformed.
listToTuple :: [String] -> Lit
listToTuple [i, c1, c2] = pairLit (IntLit $ read i, pairLit (CharLit $ head c1, CharLit $ head c2))
listToTuple _ = undefined

-- | Compares two lists of difference records field by field: each
-- disagreeing field of an aligned pair costs 1 (so index, first char and
-- second char are judged separately), and a record present on only one
-- side costs 3 - the maximum for a single position.
wrongCases :: Lit -> Lit -> Sum Integer
wrongCases (ListLit (GPair GInt (GPair GChar GChar)) as) (ListLit (GPair GInt (GPair GChar GChar)) bs) = mconcat $ alignWith (Sum . cmp) as bs
  where
    cmp :: These Lit Lit -> Integer
    cmp (This _) = 3
    cmp (That _) = 3
    cmp
      ( These
          (PairLit (IntLit i1) (PairLit (CharLit a1) (CharLit b1)))
          (PairLit (IntLit i2) (PairLit (CharLit a2) (CharLit b2)))
        ) = fromIntegral $ sum $ fromEnum <$> [i1 /= i2, a1 /= a2, b1 /= b2]
    cmp _ = error "Wrong type"
wrongCases _ _ = error "Wrong type"
