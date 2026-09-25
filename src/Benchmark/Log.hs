-- |
-- Module      : Benchmark.Log
-- Description : Everything written to disk during/after a run.
--
-- Three kinds of output, all under @./output/@:
--
-- * /.log.csv@ - one row per logging tick: time, evaluations spent, and
--   stats about the current best individual (fitness, size, accuracy on
--   the test set, pretty-printed program). This is the raw material for
--   convergence plots.
-- * /.result.csv@ - after the run: every test case with its expected and
--   produced value, plus whether they matched.
-- * /.result.json@ - after the run: a machine-readable summary of the
--   winning program (fitness, size, accuracy, NMSE, both the raw and the
--   simplified source forms).
--
-- Accuracy/NMSE are computed against the /test/ set only, which is why they
-- can be trusted as an unbiased measure of the found program.
module Benchmark.Log where

import Benchmark.Core
import Benchmark.Dataset
import Benchmark.Helpers
import Control.Applicative (liftA2)
import Control.Monad (join, unless)
import Data.List (intercalate)
import qualified Data.SortedList as SL
import Data.Time (UTCTime, getCurrentTime)
import Data.Time.Format.ISO8601
import Evolution
import Evolution.Fitness
import Grammar
import Grammar.Simplify (simplifyTree)
import Pretty
import System.Directory
import System.IO

-- | Creates the output directory (if needed) and opens the per-run log CSV
-- with its header row.
--
-- Returns the open log handle plus the paths of the two result files that
-- will be written when the run finishes.
prepareLogFiles :: String -> FilePath -> Benchmark a -> IO (Handle, FilePath, FilePath)
prepareLogFiles identifier workDir benchmark = do
  let checkpointDirectory = workDir <> "checkpoint/"
      outDirectory = workDir <> "output/"
      fileNamePrefix = outDirectory <> identifier
      logFile = fileNamePrefix <> ".log.csv"
      finalResultFile = fileNamePrefix <> ".result.csv"
      jsonFile = fileNamePrefix <> ".result.json"
  createDirectoryIfMissing True outDirectory
  createDirectoryIfMissing True checkpointDirectory
  logFileHandle <- openFile logFile WriteMode
  hPutStrLn logFileHandle csvHeader
  return (logFileHandle, finalResultFile, jsonFile)

-- | Renders the whole test set for one program as CSV: for each case, the
-- inputs, the expected output, what the program produced (or @nan@ if it
-- crashed) and a boolean for whether they matched.
logBest :: Dataset -> Tree -> String
logBest dataset t = unlines $ header : (logTestCase <$> dataset)
  where
    header = csvJoin $ ["x" <> show n | n <- [0 .. (length (fst $ head dataset) - 1)]] <> ["y", "y_hat", "right"]
    logTestCase :: TestCase -> String
    logTestCase (x, y) = csvJoin $ (pretty <$> x) <> [pretty y, maybe "nan" pretty yHat, show $ Just y == yHat] where yHat = evalTree x t

-- | Builds the JSON summary of the final program.
--
-- Two source forms are recorded:
--
-- * @stringRep@ - the program exactly as evolved;
-- * @stringRepSimple@ - after 'simplifyTree', i.e. the same program with
--   algebraic redundancy removed (usually much shorter and more readable).
--
-- @accuracy@ is the fraction of test cases answered correctly (floats
-- within 1e-4); @nmse@ is the normalised mean squared error and is @nan@
-- when either side is non-numeric.
jsonBest :: (Show a, Fitness a) => String -> Int -> Int -> Dataset -> Individual a -> String
jsonBest datasetName seed nEvals dataset ind =
  "{\n"
    <> intercalate
      ",\n"
      ( ("    " <>)
          <$> [ "datasetName" .: datasetName,
                "seed" .: seed,
                "totalEvals" .: nEvals,
                "fitness" .: logFitness (_fitness ind),
                "height" .: getHeight tree,
                "nodeCount" .: getNodeCount tree,
                "accuracy" .: accuracy,
                "nmse" .: maybe "nan" show nmse,
                "stringRepSimple" .: pretty (simplifyTree tree),
                "stringRep" .: pretty tree,
                "showTree" .: show tree
              ]
      )
    <> "\n}"
  where
    tree = _indTree ind
    (accuracy, nmse) = getAccuracyAndNmse dataset tree

-- | JSON key-value helper: @\"seed\" .: 42@ becomes @\"seed\":42@.
-- Values are 'show'n, so strings come out quoted.
(.:) :: (Show a) => String -> a -> String
key .: value = show key <> ":" <> show value

-- | Column names of the progress CSV (must match the order used by
-- 'logPop').
csvHeader :: String
csvHeader =
  csvJoin
    [ "time",
      "n_evals",
      "best_fitness",
      "best_depth",
      "best_node_count",
      "best_acc",
      "best_nmse",
      "best_string_rep_simple",
      "best_string_rep"
    ]

-- | Produces one progress-CSV row for the current best individual.
--
-- Scoring against the whole test set on every tick would be expensive, so
-- the accuracy computation is memoised: @cache@ holds the last tree scored
-- and its result, and is reused when the best individual has not changed.
logPop :: (Show a, Fitness a) => Maybe StatsCache -> Dataset -> UTCTime -> Evaluations -> SL.SortedList (Individual a) -> (String, StatsCache)
logPop cache testSet time nEvals pop =
  ( csvJoin
      [ show time, -- time
        show nEvals, -- n_evals
        logFitness . _fitness $ best, -- best_fitness
        show . getHeight $ bestTree, -- best_depth
        show . getNodeCount $ bestTree, -- best_node_count
        show accuracy, -- best_acc
        maybe "nan" show nmse, -- best_nmse
        show . pretty . simplifyTree $ bestTree, -- best_string_rep_simple
        show . pretty $ bestTree -- best_string_rep
      ],
    newCache
  )
  where
    best = head $ SL.fromSortedList pop
    bestTree = _indTree best
    ((accuracy, nmse), newCache) = memoedGetAccuracyAndNmse cache testSet bestTree

-- | Memoised version of 'getAccuracyAndNmse': computes the stats for the
-- given tree, reusing the cached entry when the tree is unchanged.
memoedGetAccuracyAndNmse :: Maybe StatsCache -> Dataset -> Tree -> ((Float, Maybe Float), StatsCache)
memoedGetAccuracyAndNmse cache testSet tree =
  let result = getAccuracyAndNmse testSet tree
   in case cache of
        Nothing -> (result, (tree, result))
        Just cache -> memoLast (getAccuracyAndNmse testSet) cache tree

-- | One-entry memo table: if the input equals the cached input, return the
-- cached output, otherwise recompute (and replace the entry).
--
-- The cache is passed around explicitly (rather than hidden in IO) because
-- the run loop is otherwise pure.
memoLast :: (Pretty a, Show a, Show b, Eq a) => (a -> b) -> (a, b) -> a -> (b, (a, b))
memoLast f t@(lastX, lastY) x
  | x == lastX = (lastY, t)
  | otherwise = let newY = f x in (newY, (x, newY))

-- | Scores a program on a dataset: (accuracy, normalised MSE).
--
-- Accuracy counts how many cases were answered correctly; NMSE is only
-- available when every expected and produced value is numeric ('Nothing'
-- otherwise, which logs as @nan@).
getAccuracyAndNmse :: Dataset -> Tree -> (Float, Maybe Float)
getAccuracyAndNmse testSet tree = (accValue, nmseValue)
  where
    ysHat = (`evalTree` tree) . fst <$> testSet
    ys = snd <$> testSet
    nmseValue = join $ liftA2 (runOnNum nmse) (Just ys) (sequence ysHat)
    accValue = accuracy (Just <$> ys) ysHat

-- | Fraction of cases where the produced value equals the expected one.
--
-- Floats are compared with a 1e-4 tolerance because the datasets round
-- their expected values; everything else must match exactly. A crashed
-- program (@Nothing@) never matches.
accuracy :: [Maybe Lit] -> [Maybe Lit] -> Float
accuracy ys ysHat = fromIntegral (length $ filter id $ zipWith litEq ys ysHat) / fromIntegral (length ys)
  where
    litEq :: Maybe Lit -> Maybe Lit -> Bool
    litEq (Just (FloatLit x)) (Just (FloatLit y)) = abs (x - y) < 1e-4
    litEq a b = a == b

-- | Applies a numeric statistic only when both sides are entirely numeric
-- ('Int' or 'Float' literals); otherwise 'Nothing'.
runOnNum :: ([Float] -> [Float] -> Float) -> [Lit] -> [Lit] -> Maybe Float
runOnNum f ys ysHat = f <$> sequence (fromNum <$> ys) <*> sequence (fromNum <$> ysHat)
  where
    fromNum :: Lit -> Maybe Float
    fromNum (IntLit x) = Just $ fromIntegral x
    fromNum (FloatLit x) = Just x
    fromNum _ = Nothing

-- | Normalised mean squared error: @MSE(pred, actual) / variance(actual)@.
--
-- Dividing by the variance of the true values makes the number comparable
-- across problems: 1.0 is no better than always predicting the mean, and
-- 0.0 is perfect.
nmse :: [Float] -> [Float] -> Float
nmse ys ysHat = mse ysHat ys / var ys
  where
    mse :: [Float] -> [Float] -> Float
    mse ys ysHat = mean $ square <$> zipWith (-) ysHat ys
    mean :: [Float] -> Float
    mean x = sum x / fromIntegral (length x)
    var :: [Float] -> Float
    var x = sum $ square . (`subtract` mean x) <$> x
    square x = x * x