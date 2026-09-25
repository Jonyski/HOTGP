-- |
-- Module      : Benchmark.BenchmarkToConfig
-- Description : Translates a Benchmark record + training data into an
--               Evolution.Config.
--
-- This is the bridge between the declarative problem description and the
-- search engine. It decides:
--
-- * the program type (from the benchmark's input/output types);
-- * the search limits - population size, tree depths and evaluation budget
--   (the constants below are the experiment's fixed hyper-parameters);
-- * the fitness function, which runs the candidate over every training
--   case and sums the metric's contributions, wrapped in 'Result' so a
--   crash on any case scores as 'Error';
-- * the two sampler tables ('full' and 'grow') restricted to the
--   benchmark's relevant types and allowed constants.
module Benchmark.BenchmarkToConfig where

import Benchmark.Core
import Benchmark.Dataset
import Benchmark.Helpers
import qualified Data.Map as M
import Data.Maybe (isJust)
import qualified Data.Set as S
import Evolution
import Grammar

-- | Builds the config for a benchmark, given its training set.
--
-- The fitness function is a fold over the training cases: for each
-- @(inputs, expected)@ it evaluates the candidate, converts a runtime
-- failure into 'Error', applies the benchmark's metric, and 'mconcat's all
-- contributions together.
makeConfig :: (Ord a, Monoid a) => Dataset -> Benchmark a -> Config (Result a)
makeConfig trainSet bench =
  MkConfig
    { _programType = MkFunctionType {_argTypes = _inputTypes bench, _outType = _outputType bench},
      _maxTreeDepth = treeDepth,
      _maxMutationTreeDepth = treeDepth,
      _maxInitialDepth = treeDepth,
      _popSize = popSize,
      -- Two parents per step => one crossed-over pair per iteration.
      _individualsPerStep = 2,
      _nEvaluations = nGens * popSize,
      _fitnessFunction = fitness,
      -- Selection decays slowly with rank: the best individual is only
      -- ~1.0007x more likely to be picked than the second best, so genetic
      -- diversity is preserved while still preferring better programs.
      _parentScalar = 0.9993,
      _crossoverRate = 0.5,
      -- Two tables over the same choices: "full" (branches must reach the
      -- bottom) and "grow" (branches may stop early).
      _fullTable = buildTable termsAndOps treeDepth True,
      _growTable = buildTable termsAndOps treeDepth False
    }
  where
    -- Fixed experiment hyper-parameters (see the paper).
    popSize = 1000
    nGens = 300
    treeDepth = 15
    -- Total fitness = sum of the metric over every training case.
    -- maybeToResult turns "the program crashed here" into Error, which the
    -- Semigroup propagates: one crash spoils the whole score.
    fitness tree = mconcat $ (\(x, y) -> _fitnessMetric bench y <$> maybeToResult (evalTree x tree)) <$> trainSet

    -- The grammar slice available to this problem: the allowed constants,
    -- the program's arguments grouped by type, and every operation that can
    -- produce a relevant type.
    termsAndOps :: TermsAndOps
    termsAndOps =
      MkTermsAndOps
        { _literals = _allowedConstants bench,
          _arguments = typesToArgMap (_inputTypes bench),
          _operations = operationsFromTypes (S.toList $ _relevantTypes bench)
        }

-- | Groups operations by the types they can produce.
--
-- For each relevant type, keep the operations whose declared output type
-- unifies with it - so a polymorphic operation like @map@ appears under
-- every type its result could take.
operationsFromTypes :: [GType] -> M.Map OutputType [Operation]
operationsFromTypes relevantTypes = M.fromList [(t, findOps t) | t <- relevantTypes]
  where
    -- Operation has Enum+Bounded, so this is "all constructors".
    ops = [(minBound :: Operation) .. maxBound]
    findOps t = filter (opMatches t) ops
    opMatches :: GType -> Operation -> Bool
    opMatches gType op = isJust $ unifyTypes gType $ opOutput op
