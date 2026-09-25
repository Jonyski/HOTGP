-- |
-- Module      : Benchmark.Problems.VectorAverage
-- Description : The arithmetic mean of a list of floats.
--
-- Given a list of floating-point numbers, produce their average - the
-- sum of the list divided by the number of elements it holds.
--
-- 'floatError' grades it: the result is continuous, so the absolute
-- difference between expected and produced value says how far off the
-- program is; an exactly right answer scores 0.
module Benchmark.Problems.VectorAverage (vectorAverage) where

import Benchmark.Core (Benchmark (..))
import Benchmark.Metrics (floatError)
import Data.Align (alignWith)
import qualified Data.Map as M
import Data.Monoid (Sum (Sum))
import qualified Data.Set as S
import Data.These (These (That, These, This))
import Evolution (randomR)
import Grammar

-- | The benchmark: the arithmetic mean of a list of floats.
vectorAverage :: Benchmark (Sum Float)
vectorAverage =
  MkBenchmark
    { _benchmarkId = Nothing,
      _datasetName = "vector-average",
      _inputTypes = [GList GFloat],
      _outputType = GFloat,
      _fitnessMetric = floatError,
      _testCases = 1000,
      _trainCases = 100,
      -- A list type is listed (as GList GInt) so that list-producing
      -- operations such as map, filter and length are offered at all;
      -- floats and ints cover the arithmetic and the element count.
      _relevantTypes = S.fromList [GList GInt, GInt, GFloat, GBool],
      _customOutputParser = Nothing,
      _allowedConstants =
        M.fromList [(GInt, [return $ IntLit 0]), (GFloat, [return $ FloatLit 0])]
    }
