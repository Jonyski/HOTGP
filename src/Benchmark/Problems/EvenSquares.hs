-- |
-- Module      : Benchmark.Problems.EvenSquares
-- Description : The even perfect squares below a bound, one per line.
--
-- Given an integer n, produce the even perfect squares that are strictly
-- smaller than n - 4, 16, 36, 64, ... - as a newline-separated string
-- (0 is not part of the answer), for instance 17 becomes "4\n16".
-- 'parseOutput' splits that text back into a list of integers.
--
-- 'wrongCases' grades it: positions present on both sides are compared
-- with 'intError', while an element found on only one side is charged
-- its own absolute value - a wrong number, a missing line and an extra
-- line therefore all push the score up.
module Benchmark.Problems.EvenSquares (evenSquares) where

import Benchmark.Core
import Benchmark.Helpers
import Benchmark.Metrics
import Benchmark.Parse
import Data.Aeson (Value (String))
import Data.Align
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import qualified Data.Text as T
import Data.These
import Evolution (randomR)
import Grammar

-- | The benchmark: the even perfect squares below the input, one per line.
evenSquares :: Benchmark (Sum Integer)
evenSquares =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "even-squares",
      _inputTypes = [GInt],
      _outputType = GList GInt,
      _fitnessMetric = wrongCases,
      _testCases = 1000,
      _trainCases = 100,
      -- Floats are relevant because reaching the bound uses sqrt/floor;
      -- lists and unary lambdas because the answer is a filtered list
      -- built with map and filter.
      _relevantTypes = S.fromList $ (allowList <> allowUnaryLambdas) [GInt, GBool, GFloat],
      -- The dataset stores the answer as one string of newline-separated
      -- numbers, not as a JSON array, so the default output1 parser would
      -- fail on it - hence a custom one.
      _customOutputParser = Just parseOutput,
      _allowedConstants = M.empty
    }

-- | The dataset's @output1@ is a single string of newline-separated
-- numbers; split it on newlines and read each line as an integer.
parseOutput :: OutputParser
parseOutput obj = tListLitOf GInt IntLit $ map (read . T.unpack) $ T.lines txt
  where
    String txt = obj ^. "output1"

-- | Scores two integer lists against each other: aligned positions cost
-- their numeric difference (via 'intError'), and an element present on
-- only one side costs its own absolute value, so length mismatches are
-- punished as well as value mismatches.
wrongCases :: Lit -> Lit -> Sum Integer
wrongCases (ListLit GInt as) (ListLit GInt bs) = mconcat $ alignWith cmp as bs
  where
    cmp :: These Lit Lit -> Sum Integer
    cmp (This (IntLit a)) = Sum $ fromIntegral $ abs a
    cmp (That (IntLit b)) = Sum $ fromIntegral $ abs b
    cmp (These a b) = intError a b
    cmp _ = error "Wrong Type!"
wrongCases _ _ = error "Wrong type"
