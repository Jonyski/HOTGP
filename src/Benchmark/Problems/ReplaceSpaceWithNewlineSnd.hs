-- |
-- Module      : Benchmark.Problems.ReplaceSpaceWithNewlineSnd
-- Description : Only the count half of replace-space-with-newline.
--
-- Given a string, produce the number of its characters that are not
-- spaces - the @output2@ field of the shared replace-space-with-newline
-- dataset, asked for on its own rather than as part of a pair. For
-- example "i !i" has 3 non-space characters.
--
-- 'intError' grades it: the answer is an exact integer, and being k off
-- costs k, which gives the search a graded signal instead of a flat
-- right/wrong penalty.
--
-- The dataset is shared with two sibling problems, so '_benchmarkId'
-- gives this one a name of its own - otherwise looking a problem up by
-- name would collide with the pair version.
module Benchmark.Problems.ReplaceSpaceWithNewlineSnd where

import Benchmark.Core (Benchmark (..))
import Benchmark.Helpers (allowList, allowPairs, allowUnaryLambdas)
import Benchmark.Metrics (floatError, intError, levenshteinDistance)
import Benchmark.Parse
import Control.Monad (replicateM)
import qualified Data.Map as M
import Data.Monoid (Sum)
import qualified Data.Set as S
import Evolution (St, random, randomR)
import Grammar

-- | The benchmark: just the count of characters that are not spaces.
--
-- '_benchmarkId' is set explicitly because the dataset name is shared
-- with the two sibling variants of this problem: without a distinct CLI
-- name, looking this problem up would collide with the pair version.
replaceSpaceWithNewlineSnd :: Benchmark (Sum Integer)
replaceSpaceWithNewlineSnd =
  MkBenchmark
    { _benchmarkId = Just "replace-space-with-newline-snd",
      _datasetName = "replace-space-with-newline",
      _inputTypes = [GList GChar],
      _outputType = GInt,
      _fitnessMetric = intError,
      _testCases = 1000,
      _trainCases = 100,
      -- No pairs: with only one output field there is nothing to zip.
      -- Lists and unary lambdas, because the count comes from a filter.
      _relevantTypes = S.fromList $ allowUnaryLambdas baseTypes <> allowList [GChar],
      -- The default parser would do here (it reads output1), but an
      -- explicit one documents which of the two fields is wanted.
      _customOutputParser = Just parseOutput,
      _allowedConstants =
        M.fromList
          -- The character being filtered out (' ') and the character
          -- the sibling problem replaces it with ('\n'), plus a
          -- random printable ERC.
          [ (GChar, (pure . CharLit <$> [' ', '\n']) <> [CharLit <$> randomR ('!', '~')]),
            -- A random string constant: see 'stringErc' below.
            (GList GChar, [stLit <$> stringErc])
          ]
    }
  where
    baseTypes = [GBool, GChar, GInt]

-- | Reads only @output2@ - the expected count of non-space characters.
parseOutput :: OutputParser
parseOutput obj = parseJsonLit GInt (obj ^. "output2")

-- | A random lowercase string constant (an ERC) of length 0-20 with
-- about 20% spaces, so the search has example-shaped string literals
-- available for crossover and mutation.
stringErc :: St String
stringErc = do
  len <- randomR (0, 20 :: Int)
  replicateM len $ do
    space <- (< 0.2) <$> randomR (0, 1.0 :: Float)
    if space then return ' ' else randomR ('a', 'z')
