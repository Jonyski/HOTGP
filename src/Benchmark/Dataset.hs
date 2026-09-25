-- |
-- Module      : Benchmark.Dataset
-- Description : Loading datasets and splitting them into train/test sets.
--
-- A dataset is a list of test cases, each being a pair of (inputs, expected
-- output) in the grammar's value language. This module is responsible for
-- reading the JSON files produced by "Benchmark.Download" and for cutting
-- them into the pieces the rest of the system expects.
--
-- Splitting policy (see 'loadTrainAndTestSet'):
--
-- 1. concatenate the /edge/ cases first, then the /random/ ones - edge cases
--    are the interesting corner conditions and should always be seen during
--    training;
-- 2. the first _trainCases_ examples form the training set (these are what
--    the fitness function scores);
-- 3. the next _testCases_ examples form the test set (only used for
--    reporting, so a program cannot overfit its way to a good log line).
--
-- Because "Benchmark.Download" shuffles the random file on download, both
-- halves are effectively random samples.
module Benchmark.Dataset where

import Benchmark.Core
import Benchmark.Download
import Benchmark.Parse
import qualified Control.Monad.State.Strict as S
import Data.Aeson
import qualified Data.ByteString.Lazy as B
import Data.Either (fromRight)
import Data.HashMap.Strict ((!?))
import Data.List (intercalate)
import Data.List.Split (chunksOf, splitOn)
import Data.Maybe (fromJust, fromMaybe)
import qualified Data.Vector as V
import Grammar.Core (Lit)
import System.Random (mkStdGen)

-- | One example: the program's inputs and the expected output.
type TestCase = ([Lit], Lit)

-- | A collection of examples.
type Dataset = [TestCase]

-- | Loads the dataset and splits it into the training and test sets.
--
-- This is what "Benchmark.Run" calls before starting a run; it downloads
-- the files on first use.
loadTrainAndTestSet :: FilePath -> Benchmark a -> IO (Dataset, Dataset)
loadTrainAndTestSet workDir benchmark = do
  downloadBenchmark workDir (_datasetName benchmark)
  random <- readJson workDir benchmark "-random.json"
  edge <- readJson workDir benchmark "-edge.json"
  -- Edge cases come first so they are always part of the training set.
  let (trainSet, remaining) = splitAt (_trainCases benchmark) $ edge <> random
      testSet = take (_testCases benchmark) remaining
  return (trainSet, testSet)

-- | Loads a single cross-validation fold: 'foldNumber'-th validation chunk
-- plus the rest as training data.
--
-- The random cases are divided into 5 equal chunks; chunk @foldNumber@ is
-- held out as the validation set, and training gets the edge cases plus all
-- the other chunks. Used by the crossover-rate sweep
-- ("Benchmark.RunSearch"), where results must be compared across folds
-- rather than on a single fixed split.
loadTrainAndValidationSet :: Int -> FilePath -> Benchmark a -> IO (Dataset, Dataset)
loadTrainAndValidationSet foldNumber workDir benchmark = do
  downloadBenchmark workDir (_datasetName benchmark)
  random <- readJson workDir benchmark "-random.json"
  edge <- readJson workDir benchmark "-edge.json"
  -- Picks the foldNumber-th chunk out of the list (0-based).
  let getFold _ [] = undefined -- no fold left: caller asked for more folds than exist
      getFold 0 xs = (head xs, tail xs)
      getFold i (x : xs) = let (el, xs') = getFold (i -1) xs in (el, x : xs')
      trainingRandomLength = _trainCases benchmark - length edge
      trainingRandom = take trainingRandomLength random
      folds = chunksOf (trainingRandomLength `div` 5) trainingRandom
      (validationSet, rest) = getFold foldNumber folds
      trainSet = edge <> concat rest
  return (trainSet, validationSet)

-- | Reads one dataset file and converts every line into a test case.
--
-- For each JSON object, the input fields @input1..inputN@ are decoded with
-- the benchmark's declared input types, and the output with the custom
-- parser if the problem provides one, or the default @output1@ parser
-- otherwise.
readJson :: FilePath -> Benchmark a -> String -> IO [([Lit], Lit)]
readJson workDir benchmark suffix = do
  fileContents <- readFile fileName
  let contents = parseJsonLine <$> lines fileContents
  return $ transform <$> contents
  where
    fileName :: FilePath
    fileName = workDir <> csvDirs <> _datasetName benchmark <> suffix

    parseOutput :: OutputParser
    parseOutput = fromMaybe (defaultOutputParser (_outputType benchmark)) (_customOutputParser benchmark)

    -- Builds (inputs, expected output) for one JSON object. The list of
    -- input fields is infinite but zipWith stops at _inputTypes' length.
    transform :: Object -> ([Lit], Lit)
    transform obj = (zipWith parseJsonLit (_inputTypes benchmark) xs, parseOutput obj)
      where
        xs = [obj ^. ("input" <> show i) | i <- [1 ..]]
