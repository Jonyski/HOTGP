-- |
-- Module      : Benchmark.RunSearch
-- Description : Parameter sweep over the crossover rate (with k-fold
--               validation).
--
-- An alternative entry point to 'Benchmark.Run.runBenchmark': instead of a
-- fixed seed/split, it runs one fold of a 5-fold cross-validation with a
-- caller-chosen crossover rate. Sweeping @cxRate@ over several values and
-- comparing the resulting logs is how the best rate is picked empirically.
--
-- Differences from the standard runner:
--
-- * the data comes from 'loadTrainAndValidationSet' (held-out validation
--   chunk instead of a fixed test slice);
-- * @_crossoverRate@ is overridden on top of the default config;
-- * the RNG is always seeded with @0@, so across rates the only thing that
--   differs is the parameter under test.
{-# LANGUAGE ScopedTypeVariables #-}

module Benchmark.RunSearch where

import Benchmark.BenchmarkToConfig
import Benchmark.Core
import Benchmark.Dataset
import Benchmark.Download (csvDirs, downloadBenchmark)
import Benchmark.Helpers
import Benchmark.Log
import Control.Monad (unless, when)
import Control.Monad.State.Strict (evalState, evalStateT)
import qualified Data.ByteString.Lazy as B
import Data.Either (fromRight)
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.SortedList as SL
import Data.Time
import Data.Time.Format.ISO8601 (iso8601Show)
import qualified Data.Vector as V
import Evolution
import Evolution.Fitness (Fitness)
import Grammar
import Pretty
import System.Directory (createDirectory, doesDirectoryExist, doesFileExist, removeFile)
import System.IO
import System.Random (mkStdGen)

-- | Runs a single (fold, crossover rate) experiment.
--
-- @cxRate@ is expressed in /percent/ (0-100) because that is how the
-- results are reported; it is divided by 100 for the config.
searchCxRate :: (Fitness a, Monoid a, Show a) => FilePath -> Int -> Int -> Benchmark a -> IO ()
searchCxRate workDir foldNumber cxRate benchmark = do
  hSetBuffering stdout $ BlockBuffering Nothing
  putStrLn $ "Testing " <> getBenchmarkId benchmark <> " with cxRate=" <> show cxRate <> "%, on fold " <> show foldNumber
  identifier <- logFileIdentifier foldNumber cxRate benchmark
  (logFileHandle, finalResultFile, _) <- prepareLogFiles identifier workDir benchmark
  (trainSet, testSet) <- loadTrainAndValidationSet foldNumber workDir benchmark

  let cfg = (makeConfig trainSet benchmark) {_crossoverRate = fromIntegral cxRate / 100}
      checkpoint = checkpointFilename workDir foldNumber cxRate benchmark
      logToFile cache time evals pop = do
        let (row, newCache) = logPop cache testSet time evals pop
        hPutStrLn logFileHandle row
        when (evals `mod` 100 == 0) $ hFlush logFileHandle
        return newCache

  (finalPop, _) <- evalStateT (runAndLog cfg logToFile checkpoint) $ mkStdGen 0

  hClose logFileHandle
  writeFile finalResultFile $ logBest testSet (_indTree $ head $ SL.fromSortedList finalPop)

-- shouldRemoveCheck <- doesFileExist checkpoint
-- when shouldRemoveCheck $ removeFile checkpoint

-- | Log file name for a sweep run: timestamp + fold + rate + problem.
logFileIdentifier :: Int -> Int -> Benchmark a -> IO String
logFileIdentifier foldNumber cxRate benchmark = do
  time <- getCurrentTime
  return $ iso8601Show time <> "_f" <> show foldNumber <> "_cx" <> show cxRate <> "_" <> getBenchmarkId benchmark

-- | Checkpoint path for a sweep run (fold and rate are part of the key so
-- sweeps of different parameters never resume each other's state).
checkpointFilename :: FilePath -> Int -> Int -> Benchmark a -> FilePath
checkpointFilename _ foldNumber cxRate benchmark = "./checkpoint/" <> "f" <> show foldNumber <> "_cx" <> show cxRate <> "_" <> getBenchmarkId benchmark <> ".checkpoint"
