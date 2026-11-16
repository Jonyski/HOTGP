{-# LANGUAGE TupleSections #-}

-- |
-- Program      : hotgp
-- Description  : Command-line entry point for the HOTGP benchmark runner.
--
-- Usage (via @stack run@ / @cabal run@):
--
-- @
-- stack run <benchmark_name> <seed>           -- run one problem with a given seed
-- stack run <benchmark_name> <seed> --gpu     -- ... scoring the initial
--                                             -- population as one batch on the
--                                             -- CUDA runner
-- stack run <benchmark_name> <seed> --gpu-cpu -- ... same batch, on the CPU
--                                             -- reference (no CUDA needed)
-- stack run prune                             -- prune programs in input-prune/
-- @
--
-- With no valid arguments the program prints the help text, which includes
-- the list of available benchmarks (taken straight from
-- "Benchmark.Problems.allProblemIds", so it can never go stale).
--
-- Both commands share the working directory: datasets are downloaded into
-- @./datasets/@, logs are written to @./output/@, and run state is kept in
-- @./checkpoint/@ (created on startup, which is why 'main' calls
-- 'createDirectoryIfMissing' before dispatching).
module Main where

import Benchmark.Gpu (Backend (..))
import Benchmark.Problems (allProblemIds, runProblemWith)
import Data.List (sort)
import Prune (prune)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, lookupEnv)
import Text.Read (readMaybe)

-- | All files are written relative to the current directory.
workDir :: FilePath
workDir = "./"

main :: IO ()
main = do
  args <- getArgs
  createDirectoryIfMissing True "./checkpoint"
  parsed <- parseArgs args
  case parsed of
    Nothing -> do
      case args of
        ["prune"] -> prune
        _ -> showHelp
    -- A well-formed run: the named problem, that seed, and where (if
    -- anywhere) to batch-score the initial population.
    Just (name, seed, backend) -> runProblemWith backend workDir seed name

-- | Prints the usage message and the available benchmark names.
showHelp :: IO ()
showHelp =
  do
    putStrLn "Invalid args!"
    putStrLn "Usage:"
    putStrLn "\tstack run prune"
    putStrLn "\tstack run <benchmark_name> <seed_number> [--gpu | --gpu-cpu]"
    putStrLn "\n--gpu scores the initial population as one batch on the CUDA runner"
    putStrLn "(--gpu-cpu: the same batch, on the in-process flattened CPU evaluator)."
    putStrLn "The runner path is $HOTGP_GPU_RUNNER, default ./gpu/gp_eval."
    putStrLn "\nHere are the available benchmarks:"
    putStr $ unlines $ map ('\t' :) $ sort allProblemIds

-- | What the user asked for regarding batched scoring.
data BatchFlag
  = -- | Score the initial population one tree at a time (the historical
    -- behaviour, and what the steady-state loop does for its children).
    Serial
  | -- | Batch on the in-process flattened evaluator ("Grammar.Flat").
    BatchCpu
  | -- | Batch on the external CUDA runner, whose executable 'main' resolves.
    BatchGpu
  deriving (Eq, Show)

-- | Interprets the command line.
--
-- @Just (name, seed, backend)@ only when the first two arguments are a known
-- benchmark and an 'Int' and the rest is a single optional scoring flag.
-- Everything else (including @prune@) yields 'Nothing' and is handled by the
-- caller.
parseArgs :: [String] -> IO (Maybe (String, Int, Maybe Backend))
parseArgs (nameString : seedString : rest)
  | nameString `elem` allProblemIds,
    Just seed <- readMaybe seedString,
    Just flag <- parseFlag rest =
      Just . (nameString, seed,) <$> resolve flag
  where
    -- The runner path is an environment lookup, so resolving the flag is IO.
    -- It is only consulted for @--gpu@; the serial path stays serial.
    resolve Serial = pure Nothing
    resolve BatchCpu = pure (Just CpuReference)
    resolve BatchGpu = Just . ExternalRunner <$> runnerPath
parseArgs _ = pure Nothing

-- | Reads the optional trailing scoring flag.
parseFlag :: [String] -> Maybe BatchFlag
parseFlag [] = Just Serial
parseFlag ["--gpu-cpu"] = Just BatchCpu
parseFlag ["--gpu"] = Just BatchGpu
parseFlag _ = Nothing

-- | The CUDA runner executable: @HOTGP_GPU_RUNNER@ if set, otherwise the
-- default build location of @gpu/Makefile@.
--
-- The note is printed rather than dying: the batch will fail with the
-- runner's own error message if the path is wrong, and that message says
-- which executable was missing.
runnerPath :: IO FilePath
runnerPath = do
  fromEnv <- lookupEnv "HOTGP_GPU_RUNNER"
  case fromEnv of
    Just p -> pure p
    Nothing -> do
      putStrLn "note: HOTGP_GPU_RUNNER not set, using ./gpu/gp_eval"
      pure "./gpu/gp_eval"
