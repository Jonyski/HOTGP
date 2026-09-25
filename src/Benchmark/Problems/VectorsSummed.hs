-- |
-- Module      : Benchmark.Problems.VectorsSummed
-- Description : Add two vectors element by element.
--
-- Given two lists of integers of the same length, produce the list whose
-- i-th element is the sum of the i-th elements of the two inputs -
-- [3,5,7] and [8,1,2] become [11,6,9]. The upstream cases always pair
-- lists of equal length.
--
-- 'fitnessMetric' exists because neither stock metric fits: edit
-- distance would count a wrong number as one edit no matter how wrong it
-- is, so instead every aligned position costs its numeric difference,
-- and an element present on only one side costs its own absolute value.
module Benchmark.Problems.VectorsSummed (vectorsSummed) where

import Benchmark.Core (Benchmark (..))
import Benchmark.Helpers (allowList, allowPairs, allowUnaryLambdas)
import Data.Align (alignWith)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Data.These (These (That, These, This))
import Evolution (randomR)
import Grammar

-- | The benchmark: the element-wise sum of two equally long integer
-- lists.
vectorsSummed :: Benchmark (Sum Integer)
vectorsSummed =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "vectors-summed",
      _inputTypes = [GList GInt, GList GInt],
      _outputType = GList GInt,
      _fitnessMetric = fitnessMetric,
      _testCases = 1500,
      _trainCases = 150,
      -- Pairs are what zip produces: the usual implementation zips the
      -- two inputs and then maps an addition over the pairs.
      _relevantTypes = S.fromList $ (allowUnaryLambdas <> allowList) (allowPairs [GInt]),
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList [(GInt, [intRng])]
    }
  where
    intRng = IntLit <$> randomR (-1000, 1000)

-- | Scores two integer lists position by position: aligned elements
-- cost their numeric difference, while an element found on only one side
-- costs its own absolute value, so both wrong sums and length
-- mismatches push the score up. Non-integer lists would be a bug in the
-- benchmark, hence the 'undefined' fallbacks.
fitnessMetric :: Lit -> Lit -> Sum Integer
fitnessMetric (ListLit _ x) (ListLit _ y) = mconcat $ Sum . abs <$> alignWith f x y
  where
    f (These (IntLit a) (IntLit b)) = toInteger a - toInteger b
    f (This (IntLit a)) = toInteger a
    f (That (IntLit a)) = toInteger a
    f x = undefined
fitnessMetric a b = undefined
