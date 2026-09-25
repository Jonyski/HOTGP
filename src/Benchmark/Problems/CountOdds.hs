-- |
-- Module      : Benchmark.Problems.CountOdds
-- Description : How many elements of a list are odd?
--
-- Given a list of integers, produce the number of odd elements it
-- contains. Parity is the mathematical one, so -9 counts as odd, and an
-- empty list gives 0.
--
-- 'intError' is the metric because the answer is an exact count: being
-- k off costs k, which gives the search a graded signal (closer counts
-- are better) while still reaching 0 only on a perfect answer.
module Benchmark.Problems.CountOdds (countOdds) where

import Benchmark.Core (Benchmark (..))
import Benchmark.Helpers
import Benchmark.Metrics
import Data.Align (alignWith)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | The benchmark: count the odd elements of a list of integers.
countOdds :: Benchmark (Sum Integer)
countOdds =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "count-odds",
      _inputTypes = [GList GInt],
      _outputType = GInt,
      _fitnessMetric = intError,
      _testCases = 2000,
      _trainCases = 200,
      -- allowUnaryLambdas: the natural solution is a filter whose
      -- predicate is a function of one element (odd? = mod 2 == 1), so
      -- the slice must admit unary function types.
      _relevantTypes = S.fromList $ allowUnaryLambdas [GList GInt, GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [ ( GInt,
              -- The literals a counting program is likely to need (0 as a
              -- starting count, 1 and 2 for the parity test), plus a
              -- random integer ERC for any other numeric literal.
              map
                (IntLit <$>)
                [ return 0,
                  return 1,
                  return 2,
                  randomR (-1000, 1000)
                ]
            )
          ]
    }
