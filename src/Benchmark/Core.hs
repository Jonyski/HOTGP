-- |
-- Module      : Benchmark.Core
-- Description : The description of a single benchmark problem.
--
-- A 'Benchmark' is a declarative problem statement: \"find a program with
-- these inputs and this output that matches these test cases, using only
-- this slice of the grammar, scored with this metric\".
--
-- It contains no behaviour - the same record drives dataset downloading
-- ("Benchmark.Download"), train/test splitting ("Benchmark.Dataset"),
-- configuration building ("Benchmark.BenchmarkToConfig") and logging
-- ("Benchmark.Log"). Adding a new problem therefore means writing one
-- record, not touching any of the machinery.
--
-- See "Benchmark.Problems" for the registry of available problems and
-- "Benchmark.Problems.CountOdds" for a typical example.
module Benchmark.Core where

import Benchmark.Parse (OutputParser)
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Evolution
import Grammar

-- | A benchmark problem.
--
-- The type parameter @a@ is the raw fitness metric (before being wrapped in
-- 'Benchmark.Helpers.Result'); it appears in '_fitnessMetric'.
data Benchmark a = MkBenchmark
  { -- | Name of the csv file to be downloaded from github
    -- (see "Benchmark.Download"; also the on-disk directory name).
    _datasetName :: String,
    -- | How the CLI will identify this benchmark. Defaults to _datasetName.
    -- Set it when the dataset name is not a valid CLI identifier.
    _benchmarkId :: Maybe String,
    -- | Types for parsing the arguments from the csv - also the argument
    -- types of the program being searched for.
    _inputTypes :: ProgramArgTypes,
    -- | Types for parsing the expected result from the csv.
    _outputType :: OutputType,
    -- | How can we compare two answers?
    -- Takes (expected, actual) and returns the contribution of that test
    -- case to the total fitness (summable via 'Data.Monoid.mconcat').
    _fitnessMetric :: Lit -> Lit -> a,
    -- | How many test cases should we use in total?
    _testCases :: Int,
    -- | How many train cases should we use in total?
    -- Training cases drive the search; test cases are only used for
    -- reporting, so a program can never overfit its way to a logged win.
    _trainCases :: Int,
    -- | Types allowed to exist in the context of the program.
    -- Restricting this keeps the sampler's tables small and the search
    -- focused: a numeric problem does not need pair operations available.
    _relevantTypes :: Set GType,
    -- | Which constants are we going to allow for each of the types?
    -- Actions (not values) because some constants are random draws.
    _allowedConstants :: Map GType [St Lit],
    -- | Should this problem parse its output differently?
    -- For problems whose expected output is not the last CSV column.
    _customOutputParser :: Maybe OutputParser
  }

-- | The last computed (accuracy, nmse) pair for a tree, used to avoid
-- re-scoring the same best individual on every log line. See
-- 'Benchmark.Log.memoLast'.
type StatsCache = (Tree, (Float, Maybe Float))

-- | The identifier used by the CLI and in file names.
getBenchmarkId :: Benchmark a -> String
getBenchmarkId b = fromMaybe (_datasetName b) (_benchmarkId b)