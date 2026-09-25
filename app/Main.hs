{-# LANGUAGE TupleSections #-}

-- |
-- Program      : hotgp
-- Description  : Command-line entry point for the HOTGP benchmark runner.
--
-- Usage (via @stack run@ / @cabal run@):
--
-- @
-- stack run <benchmark_name> <seed>   -- run one problem with a given seed
-- stack run prune                     -- prune programs in input-prune/
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

import Benchmark.Problems (allProblemIds, runProblem)
import Data.List (sort)
import Prune (prune)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import Text.Read (readMaybe)

-- | All files are written relative to the current directory.
workDir :: FilePath
workDir = "./"

main :: IO ()
main = do
  args <- getArgs
  let parsed = parseArgs args
  createDirectoryIfMissing True "./checkpoint"
  case parsed of
    Nothing -> do
      case args of
        ["prune"] -> prune
        _ -> showHelp
    -- Two well-formed arguments: run the named problem with that seed.
    Just (name, seed) -> runProblem workDir seed name

-- | Prints the usage message and the available benchmark names.
showHelp :: IO ()
showHelp =
  do
    putStrLn "Invalid args!"
    putStrLn "Usage:"
    putStrLn "\tstack run prune"
    putStrLn "\tstack run <benchmark_name> <seed_number>"
    putStrLn "\nHere are the available benchmarks:"
    putStr $ unlines $ map ('\t' :) $ sort allProblemIds

-- | Interprets the command line: @Just (name, seed)@ only when there are
-- exactly two arguments, the first names a known benchmark, and the second
-- parses as an 'Int'. Everything else (including @prune@) yields 'Nothing'
-- and is handled by the caller.
parseArgs :: [String] -> Maybe (String, Int)
parseArgs [nameString, seedString] =
  if nameString `elem` allProblemIds
    then (nameString,) <$> readMaybe seedString
    else Nothing
parseArgs _ = Nothing
