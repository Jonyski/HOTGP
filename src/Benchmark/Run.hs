-- |
-- Module      : Benchmark.Run
-- Description : End-to-end runner for a single benchmark problem.
--
-- This is the module the CLI ultimately calls. One run consists of:
--
-- 1. opening the log files (a per-iteration CSV plus two result files);
-- 2. downloading and splitting the dataset into train/test;
-- 3. building the 'Config' from the benchmark description;
-- 4. running the evolution ('runAndLog'), appending one CSV row per logging
--    callback and checkpointing periodically;
-- 5. writing the final best program to disk, both as a per-test-case CSV
--    and as a JSON summary for later analysis.
--
-- The seed is an explicit argument: the same @(problem, seed)@ pair always
-- reproduces the same run, including its resumed checkpoints.
{-# LANGUAGE ScopedTypeVariables #-}

module Benchmark.Run where

import Benchmark.BenchmarkToConfig (makeConfig)
import Benchmark.Core
import Benchmark.Dataset
import Benchmark.Download (csvDirs, downloadBenchmark)
import Benchmark.Gpu (Backend (..), BatchScorer (..), BatchStats (..), mkBatchScorer)
import Benchmark.Helpers
import Benchmark.Log
import Control.Monad (unless, when)
import Control.Monad.State.Strict (evalState, evalStateT)
import qualified Data.ByteString.Lazy as B
import Data.Either (fromRight)
import qualified Data.Map as M
import qualified Data.Set as S
import Data.SortedList (fromSortedList)
import qualified Data.SortedList as SL
import Data.Time
import Data.Time.Format.ISO8601 (iso8601Show)
import qualified Data.Vector as V
import Evolution
import Evolution.Fitness (Fitness)
import Evolution.Individual (SortedPop)
import Grammar
import Pretty
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, removeFile)
import System.IO
import System.Random (mkStdGen)
import Text.Printf (printf)

-- | Runs one benchmark to completion and writes its outputs.
--
-- @workDir@ is where datasets, logs and checkpoints live; @seed@ selects
-- the random stream; @benchmark@ describes the problem.
--
-- This is the serial path: the initial population is scored one tree at a
-- time, exactly as the steady-state loop scores its children.
runBenchmark :: (Fitness a, Monoid a, Show a) => FilePath -> Int -> Benchmark a -> IO ()
runBenchmark = runBenchmarkWith Nothing

-- | 'runBenchmark' with a chosen scoring backend for the
-- /initial population/.
--
-- Passing 'Just' a backend replaces the per-tree scoring of the @popSize@
-- freshly generated programs with one batched evaluation (see
-- "Benchmark.Gpu"). Nothing else about the run changes: the same trees are
-- generated from the same seed and the fitnesses are computed by the same
-- aggregation, so the search itself is identical - only the measurement is
-- faster (or slower, for problems outside the scalar subset).
--
-- The steady-state loop keeps scoring its two children per step serially,
-- because a batch of two is far too small to be worth a kernel launch. See
-- @GPU.md@ for the numbers behind that decision.
runBenchmarkWith :: (Fitness a, Monoid a, Show a) => Maybe Backend -> FilePath -> Int -> Benchmark a -> IO ()
runBenchmarkWith backend workDir seed benchmark = do
  hSetBuffering stdout $ BlockBuffering Nothing
  identifier <- logFileIdentifier benchmark seed
  (logFileHandle, finalResultFile, jsonFile) <- prepareLogFiles identifier workDir benchmark
  (trainSet, testSet) <- loadTrainAndTestSet workDir benchmark

  let cfg = makeConfig trainSet benchmark
      checkpoint = checkpointFilename workDir seed benchmark
      -- Called by the run loop on every logging tick: append one CSV row
      -- (best individual's stats on the test set) and carry the memo cache
      -- forward. Flushed every 100 rows so a crash loses little.
      logToFile cache time evals pop = do
        let (row, newCache) = logPop cache testSet time evals pop
        hPutStrLn logFileHandle row
        when (evals `mod` 100 == 0) $ hFlush logFileHandle
        return newCache

  -- One scorer per run: it flattens each tree once, keeps the CUDA runner
  -- process invocation out of the tree loop, and accumulates the statistics
  -- reported below.
  batch <- traverse (\b -> mkBatchScorer b benchmark trainSet) backend
  let scorer cfg' trees = case batch of
        Nothing -> serialScorer cfg' trees
        Just bs -> do
          individuals <- _scoreTrees bs trees
          stats <- _scorerStats bs
          printf
            "batch scoring on %s: %d trees (%d flattenable, %.1f%%), %d case evaluations\n"
            (show (_scorerBackend bs))
            (_statTrees stats)
            (_statEligible stats)
            (100 * fromIntegral (_statEligible stats) / fromIntegral (max 1 (_statTrees stats)) :: Double)
            (_statBatchEvaluations stats)
          hFlush stdout
          return individuals

  (finalPop, nEvals) <- evalStateT (runAndLogWith scorer cfg logToFile checkpoint) $ mkStdGen seed

  -- putStrLn $ pp $ finalPop

  hClose logFileHandle
  -- Final artifacts: a CSV of expected-vs-actual for every test case, and
  -- a JSON summary of the winning program.
  writeFile finalResultFile $ logBest testSet (_indTree $ head $ SL.fromSortedList finalPop)
  writeFile jsonFile $ jsonBest (getBenchmarkId benchmark) seed nEvals testSet (head $ SL.fromSortedList finalPop)

-- | Builds the unique log-file name for a run: timestamp + seed + problem.
logFileIdentifier :: Benchmark a -> Int -> IO String
logFileIdentifier benchmark seed = do
  time <- getCurrentTime
  return $ show time <> "_s" <> show seed <> "_" <> getBenchmarkId benchmark

-- | Where this run's checkpoint is stored.
--
-- Keyed by seed and problem so parallel runs of different seeds never
-- clobber each other - but re-running the same pair resumes the old state.
checkpointFilename :: FilePath -> Int -> Benchmark a -> FilePath
checkpointFilename _ seed benchmark = "./checkpoint/" <> "s" <> show seed <> "_" <> getBenchmarkId benchmark <> ".checkpoint"
