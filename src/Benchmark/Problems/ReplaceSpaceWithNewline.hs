-- |
-- Module      : Benchmark.Problems.ReplaceSpaceWithNewline
-- Description : Replace spaces with newlines, and say how much is left.
--
-- Given a string, produce the pair (number of characters that are /not/
-- spaces, the same string with every space turned into a newline) - so
-- "T L" becomes (2, "T\nL").
--
-- 'fitnessMetric' scores both halves at once: 'intError' on the count
-- and 'levenshteinDistance' on the rewritten string, so a program may be
-- right about one part and still earn something for the other.
--
-- This is the full pair version of the problem; the two sibling modules
-- (replace-space-with-newline-fst and -snd) share the same dataset but
-- ask for only one of the two fields each.
module Benchmark.Problems.ReplaceSpaceWithNewline where

import Benchmark.Core (Benchmark (..))
import Benchmark.Helpers (allowList, allowPairs, allowUnaryLambdas)
import Benchmark.Metrics (floatError, intError, levenshteinDistance)
import Benchmark.Parse (OutputParser, parseJsonLit, (^.))
import Control.Monad (replicateM)
import Data.HashMap.Strict ((!?))
import qualified Data.Map as M
import Data.Monoid (Sum)
import qualified Data.Set as S
import Evolution (St, random, randomR)
import Grammar
import Pretty

-- | The benchmark: the pair (count of non-space characters, string with
-- every space replaced by a newline).
replaceSpaceWithNewline :: Benchmark (Sum Integer)
replaceSpaceWithNewline =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "replace-space-with-newline",
      _inputTypes = [GList GChar],
      _outputType = GPair GInt (GList GChar),
      _fitnessMetric = fitnessMetric,
      _testCases = 1000,
      _trainCases = 100,
      -- Pairs are relevant because the answer is a pair, and lambda types
      -- because the string is rewritten with map and counted with filter -
      -- both unary.
      _relevantTypes =
        S.fromList $
          allowUnaryLambdas baseTypes <> allowPairs [GInt, GList GChar],
      -- The default parser only reads output1; this problem needs the
      -- count from output2 as well, so it supplies its own.
      _customOutputParser = Just parseOutput,
      _allowedConstants =
        M.fromList
          -- The character the task replaces (' ') and the character it
          -- is replaced with ('\n'), plus a random printable ERC.
          [ (GChar, (pure . CharLit <$> [' ', '\n']) <> [CharLit <$> randomR ('!', '~')]),
            -- A random string constant: see 'stringErc' below.
            (GList GChar, [stLit <$> stringErc])
          ]
    }
  where
    baseTypes = [GBool, GChar, GInt, GList GChar]

-- | Builds the expected pair from both dataset fields: the count from
-- @output2@ first, the rewritten string from @output1@ second, in the
-- order '_outputType' declares them (an integer, then a string).
parseOutput :: OutputParser
parseOutput obj = pairLit (parseJsonLit GInt (obj ^. "output2"), parseJsonLit (GList GChar) (obj ^. "output1"))

-- | Scores the pair as a whole: numeric error on the count, edit
-- distance on the string, added together (both metrics return a Sum, so
-- they combine with mappend). Anything that is not a pair would be a bug
-- in the benchmark itself, hence the crash.
fitnessMetric :: Lit -> Lit -> Sum Integer
fitnessMetric (PairLit a b) (PairLit x y) = intError a x <> levenshteinDistance b y
fitnessMetric a b = error $ "Cannot apply fitness metric to " <> pretty a <> " and " <> pretty b

-- | A random lowercase string constant (an ERC) of length 0-20, about
-- 20% of whose characters are spaces - the ingredient that makes
-- examples of this problem appear as literals the search can reuse,
-- mutate and crossover instead of having to build every string from
-- scratch.
stringErc :: St String
stringErc = do
  len <- randomR (0, 20 :: Int)
  replicateM len $ do
    space <- (< 0.2) <$> randomR (0, 1.0 :: Float)
    if space then return ' ' else randomR ('a', 'z')
