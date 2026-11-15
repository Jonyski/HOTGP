{-# LANGUAGE GADTs #-}

-- | Micro-benchmark harness used to measure the optimisation work.
--
-- Modes:
--
-- * no arguments: component timings plus the measure-cache invariants;
-- * @loop@: one end-to-end @runEvolution@ with 20 000 evaluations (use this
--   for A/B comparisons between branches);
-- * @acc \<problem\> \<seed\> \<evals\>: final best fitness of a run, used to
--   compare search quality between versions.
--
-- Tip: measure with @+RTS -N1@ and pin the process (@taskset -c N@); the
-- machine this was written on was noisy enough that only the minimum of
-- several runs gave stable numbers.
module Main (main) where

import Benchmark.BenchmarkToConfig (makeConfig)
import Benchmark.Core
import Benchmark.Dataset (loadTrainAndTestSet)
import Benchmark.Problems (Problem (MkProblem), getProblem)
import Benchmark.Problems.SumOfSquares (sumOfSquares)
import Control.Exception (evaluate)
import Control.Monad.State.Strict (evalState, runState)
import qualified Data.SortedList as SL
import Evolution
import Evolution.Crossover (crossOver)
import Evolution.Fitness (logFitness)
import Evolution.Individual (Individual (_fitness, _indTree), bestIndividual)
import Grammar
import System.CPUTime
import System.Environment (getArgs)
import System.Random (mkStdGen)
import Text.Printf

timeIt :: String -> IO a -> IO a
timeIt label act = do
  t0 <- getCPUTime
  r <- act
  t1 <- getCPUTime
  printf "%-40s %9.2f ms\n" label (fromIntegral (t1 - t0) / 1.0e9 :: Double)
  return r

forcePop :: SL.SortedList (Individual a) -> Integer
forcePop p = sum [fromIntegral (getNodeCount (_indTree i)) | i <- SL.fromSortedList p]

main :: IO ()
main = do
  args <- getArgs
  case args of
    ["acc", pid, seed, evals] -> accuracy pid (read seed) (read evals)
    _ | "loop" `elem` args -> loopMode
    _ -> components
  where
    loopMode = do
      (train, _) <- loadTrainAndTestSet "./" sumOfSquares
      let cfg = (makeConfig train sumOfSquares) {_nEvaluations = 20000}
      a <- timeIt "runEvolution 20000 evals" $ evaluate (forcePop (evalState (runEvolution cfg) (mkStdGen 1)))
      printf "checksum %s\n" (show a)
      let finalPop = SL.fromSortedList (evalState (runEvolution cfg) (mkStdGen 1))
      printf "population trees with a stale measure: %d/%d\n" (length [() | i <- finalPop, _indTree i /= computeMeasure (_indTree i)]) (length finalPop)

    components = do
      (train, test) <- loadTrainAndTestSet "./" sumOfSquares
      let cfg = makeConfig train sumOfSquares
          cfgN k = cfg {_nEvaluations = k}
      printf "train=%d test=%d nEvals=%d pop=%d\n" (length train) (length test) (_nEvaluations cfg) (_popSize cfg)

      p0 <- timeIt "init population (ramped + score)" $ evaluate (forcePop (evalState (runEvolution (cfgN 0)) (mkStdGen 42)))
      printf "  checksum %s\n" (show p0)

      let pop = evalState (ramped cfg) (mkStdGen 42) :: [Tree]
          measured = map computeMeasure pop
          pairs = zip measured (drop 1 measured)
          n = 300
          children = concat [maybe [] (\(a, b) -> [a, b]) (evalState (crossOver cfg t1 t2) (mkStdGen i)) | (i, (t1, t2)) <- zip [0 ..] (take n (cycle pairs))]
          mutants = [evalState (mutate cfg c) (mkStdGen i) | (i, c) <- zip [0 ..] (take 200 (cycle children))]
      printf "crossovers=%d children=%d mutants=%d\n" n (length children) (length mutants)
      printf "children with an inconsistent measure cache: %d\n" (length [() | c <- children, c /= computeMeasure c])
      printf "mutants  with an inconsistent measure cache: %d\n" (length [() | c <- mutants, c /= computeMeasure c])

      _ <- timeIt "crossover (300 pairs)" $ evaluate (length [() | (i, (t1, t2)) <- zip [0 ..] (take n (cycle pairs)), Just _ <- [evalState (crossOver cfg t1 t2) (mkStdGen i)]])
      _ <- timeIt "mutation (200 children)" $ evaluate (sum [getNodeCount t | t <- mutants])
      _ <- timeIt "dedup vs 1000-tree population" $ evaluate (length (filter (`notElem` measured) children))
      _ <- timeIt "fitness (children, 50 cases each)" $ evaluate (sum [fromIntegral (length (show (_fitnessFunction cfg c))) | c <- children])

      a <- timeIt "runEvolution 20000 evals" $ evaluate (forcePop (evalState (runEvolution (cfgN 20000)) (mkStdGen 1)))
      b <- timeIt "runEvolution 20000 evals (again)" $ evaluate (forcePop (evalState (runEvolution (cfgN 20000)) (mkStdGen 1)))
      let (p, g) = runState (runEvolution (cfgN 20000)) (mkStdGen 1)
      printf "checksums %s %s\n" (show a) (show b)
      printf "rng=%s best-sizes=%s\n" (show g) (show (map (getNodeCount . _indTree) (take 5 (SL.fromSortedList p))))

accuracy :: String -> Int -> Int -> IO ()
accuracy pid seed evals = case getProblem pid of
  Just (MkProblem bench) -> do
    (train, _) <- loadTrainAndTestSet "./" bench
    let cfg = (makeConfig train bench) {_nEvaluations = evals}
        pop = evalState (runEvolution cfg) (mkStdGen seed)
    putStrLn $ pid ++ " seed=" ++ show seed ++ " best=" ++ logFitness (_fitness (bestIndividual pop))
  Nothing -> putStrLn $ "unknown problem: " ++ pid
