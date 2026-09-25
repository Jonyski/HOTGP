-- |
-- Module      : Benchmark.Problems
-- Description : The registry of benchmark problems and the CLI's problem
--               dispatcher.
--
-- This module is the catalogue: it imports every individual problem
-- definition, exposes them as a list, and provides the lookup functions the
-- CLI uses to turn a name typed by the user into a runnable 'Problem'.
--
-- 'Problem' is an existential wrapper around @Benchmark a@: problems
-- differ in their fitness types (@Sum Integer@, @Sum Float@, ...), so the
-- wrapper hides that type while keeping the 'Fitness'\/'Monoid'\/'Show'
-- constraints the runner needs. The result is a homogeneous list of
-- problems that can each be run without the caller knowing their types.
--
-- Adding a new benchmark
-- ----------------------
-- 1. create @Benchmark.Problems.MyProblem@ exporting a @Benchmark a@ value;
-- 2. add it to 'allProblems' below;
-- 3. it automatically appears in @stack run@'s help text.
{-# LANGUAGE GADTs #-}

module Benchmark.Problems (runProblem, allProblemIds, searchCxRateProblem, getProblem, Problem (MkProblem)) where

import Benchmark.Core
import Benchmark.Problems.CollatzNumbers (collatzNumbers)
import Benchmark.Problems.CompareStringLengths (compareStringLengths)
import Benchmark.Problems.CountOdds (countOdds)
import Benchmark.Problems.Digits (digits)
import Benchmark.Problems.DoubleLetters (doubleLetters)
import Benchmark.Problems.EvenSquares (evenSquares)
import Benchmark.Problems.ForLoopIndex (forLoopIndex)
import Benchmark.Problems.Grade (grade)
import Benchmark.Problems.LastIndexOfZero (lastIndexOfZero)
import Benchmark.Problems.Median (median)
import Benchmark.Problems.MirrorImage (mirrorImage)
import Benchmark.Problems.NegativeToZero (negativeToZero)
import Benchmark.Problems.NumberIO (numberIO)
import Benchmark.Problems.ReplaceSpaceWithNewline (replaceSpaceWithNewline)
import Benchmark.Problems.ReplaceSpaceWithNewlineFst (replaceSpaceWithNewlineFst)
import Benchmark.Problems.ReplaceSpaceWithNewlineSnd (replaceSpaceWithNewlineSnd)
import Benchmark.Problems.SmallOrLarge (smallOrLarge)
import Benchmark.Problems.Smallest (smallest)
import Benchmark.Problems.StringDifferences (stringDifferences)
import Benchmark.Problems.StringLengthsBackwards (stringLengthsBackwards)
import Benchmark.Problems.SumOfSquares (sumOfSquares)
import Benchmark.Problems.Syllables (syllables)
import Benchmark.Problems.VectorAverage (vectorAverage)
import Benchmark.Problems.VectorsSummed (vectorsSummed)
import Benchmark.Problems.WallisPi (wallisPi)
import Benchmark.Run (runBenchmark)
import Benchmark.RunSearch (searchCxRate)
import Data.List (find)
import Data.Maybe (fromMaybe)
import Evolution (runAndLog)
import Evolution.Fitness (Fitness)

-- | A problem whose fitness type has been hidden.
--
-- The constructor carries the constraints that 'runBenchmark' requires, so
-- pattern-matching on it brings them into scope without the caller having
-- to name the type.
data Problem where
  MkProblem :: (Fitness a, Monoid a, Show a) => Benchmark a -> Problem

-- | Every benchmark this build knows about.
--
-- @collatzNumbers@ is commented out: it remains in the tree as a reference
-- but is not part of the standard set.
allProblems :: [Problem]
allProblems =
  [ --MkProblem collatzNumbers,
    MkProblem compareStringLengths,
    MkProblem countOdds,
    MkProblem digits,
    MkProblem doubleLetters,
    MkProblem evenSquares,
    MkProblem forLoopIndex,
    MkProblem grade,
    MkProblem lastIndexOfZero,
    MkProblem median,
    MkProblem mirrorImage,
    MkProblem negativeToZero,
    MkProblem numberIO,
    MkProblem replaceSpaceWithNewline,
    MkProblem replaceSpaceWithNewlineFst,
    MkProblem replaceSpaceWithNewlineSnd,
    MkProblem smallest,
    MkProblem smallOrLarge,
    MkProblem stringDifferences,
    MkProblem stringLengthsBackwards,
    MkProblem sumOfSquares,
    MkProblem syllables,
    MkProblem vectorAverage,
    MkProblem vectorsSummed,
    MkProblem wallisPi
  ]

-- | Looks up a problem by its CLI identifier.
getProblem :: String -> Maybe Problem
getProblem name = find byId allProblems
  where
    byId :: Problem -> Bool
    byId = (name ==) . problemId

-- | The CLI identifier of a problem (its dataset name unless overridden).
problemId :: Problem -> String
problemId (MkProblem b) = getBenchmarkId b

-- | All identifiers, for the help text.
allProblemIds :: [String]
allProblemIds = problemId <$> allProblems

-- | Runs a named problem to completion.
--
-- Errors on an unknown name - the CLI validates against 'allProblemIds'
-- first, so reaching this branch means the caller was bypassed.
runProblem :: FilePath -> Int -> String -> IO ()
runProblem workDir seed problemName = case getProblem problemName of
  Nothing -> error "Unknown benchmark name"
  Just (MkProblem bench) -> do
    runBenchmark workDir seed bench

-- | Runs one fold of a crossover-rate sweep on a named problem.
searchCxRateProblem :: FilePath -> Int -> Int -> String -> IO ()
searchCxRateProblem workDir foldNumber cxRate problemName = case getProblem problemName of
  Nothing -> error "Unknown benchmark name"
  Just (MkProblem bench) -> do
    searchCxRate workDir foldNumber cxRate bench
