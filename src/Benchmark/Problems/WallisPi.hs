-- |
-- Module      : Benchmark.Problems.WallisPi
-- Description : An approximation of pi from the Wallis product.
--
-- Given an integer n, produce the product of the first n terms of the
-- Wallis product, 2/3 * 4/3 * 4/5 * 6/5 * 6/7 * ... : n = 1 gives
-- 0.66667, n = 2 gives 0.88889, and the partial products oscillate
-- towards pi/4 (about 0.7854) as n grows - the familiar Wallis product
-- for pi/2 without its leading factor of 2. The dataset stores these
-- values rounded to five decimals.
--
-- 'fitnessMetric' stacks two signals: 'floatError' measures the real
-- numeric distance, while an edit distance between the pretty-printed
-- values additionally rewards a program whose printed digits already
-- agree with the expected ones.
module Benchmark.Problems.WallisPi (wallisPi) where

import Benchmark.Core
import Benchmark.Helpers (allowList, allowPairs, allowUnaryLambdas)
import Benchmark.Metrics (floatError, levenshteinDistance, prettyLevenshteinDistance)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: the n-th partial product of the Wallis product.
wallisPi :: Benchmark (Sum Float)
wallisPi =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "wallis-pi",
      _inputTypes = [GInt],
      _outputType = GFloat,
      _fitnessMetric = fitnessMetric,
      -- The only problem with more training cases (150) than test cases
      -- (50); everywhere else the test half is at least as large.
      _testCases = 50,
      _trainCases = 150,
      -- Lists, pairs and unary lambdas: the terms are produced with zip
      -- (which yields pairs of ints) and consumed with take and map.
      _relevantTypes = S.fromList $ allowUnaryLambdas $ allowList $ allowPairs [GFloat, GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [ (GFloat, [FloatLit <$> randomR (-500, 500)]),
            (GInt, [IntLit <$> randomR (-10, 10), IntLit <$> randomR (-500, 500)])
          ]
    }

-- | Scores the two floats (expected, produced): the plain numeric
-- error, plus an edit distance computed on the pretty-printed (Haskell
-- @show@) forms of both values, so two answers that print differently
-- are charged for it even when they are numerically close.
fitnessMetric :: Lit -> Lit -> Sum Float
fitnessMetric x y = floatError x y <> (fromIntegral <$> prettyLevenshteinDistance x y)
