-- |
-- Module      : Benchmark.Problems.CollatzNumbers
-- Description : The Collatz (3n+1) sequence-length problem - disabled.
--
-- Given one integer, produce the number of values the Collatz sequence
-- visits before it reaches 1, counting both the starting value and the
-- final 1: 4 -> 4,2,1 -> 3, and 3 -> 3,10,5,16,8,4,2,1 -> 8.
--
-- 'intError' grades it because the answer is a plain count - being k
-- wrong costs k. The problem is nevertheless switched off in the
-- registry (see "Benchmark.Problems"): the grammar has no unbounded
-- iteration, so no candidate tree can follow the sequence all the way to
-- its end, and the search would never converge on an answer.
module Benchmark.Problems.CollatzNumbers where

import Benchmark.Core
import Benchmark.Metrics (intError)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Evolution (randomR)
import Grammar

-- | WARNING: IMPOSSIBLE TO IMPLEMENT DUE TO POTENTIAL INFINITE LOOP (requires explicit recursion or iterateWhile)
--
-- The task in plain words: given one integer, return how many values the
-- Collatz (3n+1) sequence from that integer visits on its way to 1,
-- including the input itself and the 1 at the end.
collatzNumbers :: Benchmark (Sum Integer)
collatzNumbers =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "collatz-numbers",
      _inputTypes = [GInt],
      _outputType = GInt,
      _fitnessMetric = intError,
      _testCases = 2000,
      _trainCases = 200,
      -- No list types and no lambda types: nothing in this grammar slice
      -- can loop over a sequence, which is why the problem is unwinnable.
      _relevantTypes = S.fromList [GInt, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList
          [ (GBool, return . BoolLit <$> [True, False]),
            (GInt, [pure $ IntLit 0, pure $ IntLit 1, intRng])
          ]
    }
  where
    intRng = IntLit <$> randomR (-100, 100)