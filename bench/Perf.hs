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
import Benchmark.Gpu
import Benchmark.Gpu.Protocol (encodeBatch)
import Benchmark.Problems (Problem (MkProblem), allProblemIds, getProblem)
import Benchmark.Problems.SumOfSquares (sumOfSquares)
import Control.Exception (SomeException, evaluate, try)
import Control.Monad (forM_)
import Control.Monad.State.Strict (evalState, runState)
import Data.List (foldl', sortOn)
import qualified Data.ByteString.Lazy as BL
import qualified Data.SortedList as SL
import Evolution
import Evolution.Crossover (crossOver)
import Evolution.Fitness (Fitness, logFitness)
import Evolution.Individual (Individual (_fitness, _indTree), bestIndividual, mkIndividual)
import Grammar
import Grammar.Flat (FlatInstr (..), FlatProgram (..), evalFlat, flattenTree)
import qualified Data.Vector as V
import System.CPUTime
import System.Directory (doesFileExist)
import System.Environment (getArgs, lookupEnv)
import System.IO.Unsafe (unsafeDupablePerformIO)
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
    "gpu" : pids -> gpuMode pids
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

-- | Reports, for each benchmark: how much of its initial population fits the
-- GPU subset (by tree and by node), and the cost per evaluated node of the
-- interpreter versus the flattened evaluator.
--
-- This is the measurement behind @GPU.md@. Three details make it comparable:
--
-- * both evaluators run over /the same/ trees and /the same/ argument lists;
-- * the sample is the first 'sampleTrees' flattenable trees in population
--   order - not the largest ones. Picking by size would flatter the
--   comparison (per-node cost rises with tree size for the pointer-chasing
--   interpreter), and 'ramped' has no size bias to inherit;
-- * times are CPU time, and the results are forced inside the timed window,
--   so neither laziness nor GC scheduling can move work out of it.
--
-- Cost is reported per evaluated node, which is the only unit that transfers
-- to a GPU estimate: a kernel executes the same nodes, just thousands of
-- them at once. @GPU.md@ multiplies these numbers by the kernel's measured
-- throughput.
--
-- Usage: @hotgp-perf gpu [problem...]@ (no names = all problems).
gpuMode :: [String] -> IO ()
gpuMode pids = do
  let names = if null pids then allProblemIds else pids
  printf
    "%-24s %5s %5s %7s %6s %5s %10s %10s %8s %8s %8s\n"
    "problem"
    "cases"
    "elig%"
    "nodes%"
    "trees"
    "nodes"
    "ns/node"
    "ns/node"
    "speedup"
    "flatten"
    "encode"
  printf
    "%-24s %5s %5s %7s %6s %5s %10s %10s %8s %8s %8s\n"
    ""
    ""
    ""
    ""
    ""
    ""
    "(tree)"
    "(flat)"
    ""
    "ms"
    "ms"
  forM_ names $ \pid -> do
    r <- try (gpuRow pid) :: IO (Either SomeException ())
    case r of
      Left e -> printf "%-24s skipped (%s)\n" pid (takeWhile (/= '\n') (show e))
      Right () -> pure ()
  chainBenchmark

-- | Cost of executing one node, on programs that are guaranteed to execute
-- /every/ node.
--
-- The per-problem rows above score real trees, and a real tree often crashes
-- early (a division by zero two nodes into a 60 000-node program), so the
-- node count of a tree is only an upper bound on the work done. This chain
-- has no such escape hatch: a spine of 'AddInt' nodes has to be walked from
-- the leaf back to the root, every time.
--
-- The result is the number to compare against the kernel's throughput in
-- @GPU.md@: the kernel executes the same nodes, one thread per (program,
-- case), so "nodes per second and per core" is the transferable unit.
chainBenchmark :: IO ()
chainBenchmark = do
  -- A balanced tree, not a spine: every node executes and the value-stack
  -- depth stays at height+1 (a spine of 10 000 would need a 10 000-slot
  -- stack, which 'flattenTree' rightly refuses - the kernel's stack is a
  -- local array of 32 entries).
  let depth = 13
      tree = balanced depth
      args = [[IntLit x] | x <- [1 .. 200]]
      nodes = 2 ^ (depth + 1) - 1 :: Int
  case flattenTree 1 tree of
    Left reason -> printf "balance: flattening failed: %s\n" reason
    Right prog -> do
      let visits = nodes * length args
      treeMs <- timeMs $ forceEval [evalTree a tree | a <- args]
      flatMs <- timeMs $ forceEval [evalFlat prog a | a <- args]
      printf
        "\nbalanced tree: %d nodes x %d cases = %d node executions\n"
        nodes
        (length args)
        visits
      printf
        "balanced tree: interpreter %.1f ns/node, flattened %.1f ns/node\n"
        (treeMs * 1.0e6 / fromIntegral visits :: Double)
        (flatMs * 1.0e6 / fromIntegral visits :: Double)
  where
    balanced 0 = iLitT 1
    balanced d = AddInt <| [balanced (d - 1), balanced (d - 1)]

-- | How many trees each side of the timing comparison scores.
--
-- A prefix of the population, so the sample is unbiased; small enough that a
-- depth-15 population (|nodes| in the millions) still finishes in seconds.
sampleTrees :: Int
sampleTrees = 120

-- | One row of the report.
gpuRow :: String -> IO ()
gpuRow pid = case getProblem pid of
  Nothing -> printf "%-24s unknown problem\n" pid
  Just (MkProblem bench) -> do
    (train, _) <- loadTrainAndTestSet "./" bench
    let cfg = makeConfig train bench
        trees = evalState (ramped cfg) (mkStdGen 1)
        problem = problemFromBenchmark bench train
        cases = map fst train
        nCases = length cases
        nArgs = length (_inputTypes bench)
        (eligible, reasons) = eligibleCount nArgs trees
        flats = [(t, p) | t <- trees, Right p <- [flattenTree nArgs t]]
        nodes = sum (map getNodeCount trees)
        eligibleNodes = sum (map (getNodeCount . fst) flats)
        sample = take sampleTrees flats
        sampleNodes = sum (map (getNodeCount . fst) sample)
        -- Everything both sides touch: one visit per node per case.
        visits = sampleNodes * nCases

    -- Force the trees /before/ the timed windows: generating a depth-15 tree
    -- is expensive (~65k nodes from the sampler), it is paid identically by
    -- the serial and the batched path, and forcing it inside a window would
    -- attribute it to flattening.
    treeNodes <- timeMs $ evaluate (sum (map forceTree trees))
    printf "%-24s generation+measure: %.1f ms for %d trees (%d nodes)\n" ("" :: String) (treeNodes :: Double) (length trees) nodes

    -- The three costs of the batched path, measured separately because they
    -- are paid once per tree / once per batch and have different fixes:
    -- compiling the tree into instructions, writing the wire format, and
    -- evaluating it. (Real evaluations are only counted for the CPU
    -- comparison below; the GPU estimate uses 'chainBenchmark'.)
    flattenMs <- timeMs $ evaluate (sum [forceInstrs p | (_, p) <- sample])
    encoded <- timeMs $ evaluate (sum [fromIntegral (BL.length (encodeBatch [p] cases)) | (_, p) <- sample])
    interpMs <- timeMs $ forceEval [evalTree args t | (t, _) <- sample, args <- cases]
    flatMs <- timeMs $ forceEval [evalFlat p args | (_, p) <- sample, args <- cases]

    let perNode ms = if visits == 0 then 0 else ms * 1.0e6 / fromIntegral visits :: Double
        speedup = if flatMs <= 0 then 0 else interpMs / flatMs
    printf
      "%-24s %5d %6.1f%% %6.1f%% %6d %6d %10.1f %10.1f %7.2fx %8.1f %8.1f\n"
      pid
      nCases
      (100 * fromIntegral eligible / fromIntegral (max 1 (length trees)) :: Double)
      (100 * fromIntegral eligibleNodes / fromIntegral (max 1 nodes) :: Double)
      (length sample)
      sampleNodes
      (perNode interpMs)
      (perNode flatMs)
      speedup
      flattenMs
      encoded
    printf "%-24s ineligible: %s\n" ("" :: String) (renderReasons reasons)

    -- End-to-end check: feed a few of the same trees to the kernel runner (if
    -- it was built) and require identical fitnesses. The runner time includes
    -- process startup, request writing and response parsing - i.e. exactly
    -- what the engine pays per batch when it uses the runner.
    --
    -- Only a few trees: the request is @8 bytes per instruction@, and a
    -- depth-15 program is ~65k instructions, so a handful already makes a
    -- multi-megabyte file. That ratio is the point of the exercise (see the
    -- transfer discussion in GPU.md), not something to hide by sampling small
    -- trees.
    runner <- maybe "gpu/gp_eval_cpu" id <$> lookupEnv "HOTGP_GPU_RUNNER"
    built <- doesFileExist runner
    if not built
      then pure ()
      else do
        let subset = take 8 (map fst sample)
            subsetProblem = problem {_scoringCases = take 40 train}
        (extMs, (extern, _)) <- timed
          (scorePopulation (ExternalRunner runner) subsetProblem subset)
          (\(es, _) -> forceFitness es)
        (cpuMs, (reference, _)) <- timed
          (scorePopulation CpuReference subsetProblem subset)
          (\(rs, _) -> forceFitness rs)
        printf
          "%-24s runner: %d trees x %d cases -> %s | %.1f ms external, %.1f ms in-process\n"
          ("" :: String)
          (length subset)
          (length (_scoringCases subsetProblem))
          (if extern == reference then "same fitnesses" else "MISMATCH")
          (extMs :: Double)
          (cpuMs :: Double)

-- | Forces a list of evaluation results into a single 'Int'.
forceEval :: [Maybe Lit] -> IO Int
forceEval = evaluate . sum . map (maybe 0 (const 1))

-- | Forces every fitness in a population.
--
-- @seq@ is enough and is much cheaper than 'Show': @Result@ has a strict field,
-- so forcing an element runs the metric's arithmetic. Rendering the value would
-- dominate the measurement - a mutated integer tree can produce a number with
-- thousands of digits, and turning that into a string costs more than the
-- evaluation being measured.
forceFitness :: [a] -> IO ()
forceFitness = evaluate . foldl' (\() x -> x `seq` ()) ()

-- | Times an action and forces whatever `k` inspects, so laziness cannot leak
-- the work outside the measured window.
timed :: IO a -> (a -> IO b) -> IO (Double, a)
timed act k = do
  t0 <- getCPUTime
  v <- act
  _ <- k v
  t1 <- getCPUTime
  pure (fromIntegral (t1 - t0) / 1.0e9, v)

timeMs :: IO a -> IO Double
timeMs act = fst <$> timed act (\_ -> pure ())

-- | Forces a whole tree (the sampler yields lazy thunks).
forceTree :: Tree -> Int
forceTree (Leaf _ _) = 1
forceTree (Node _ _ children) = 1 + sum (map forceTree children)

-- | Forces every instruction of a program, so the flattener's cost is
-- attributed to the flattening column and not to the encoder that happens to
-- touch the vector's elements first.
forceInstrs :: FlatProgram -> Int
forceInstrs p = V.foldl' step 0 (_flatInstrs p)
  where
    step n (FPushArg k) = n + k + 1
    step n (FPushConst k) = n + k + 1
    step n (FApply op) = n + fromEnum op + 1

renderReasons :: [(String, Int)] -> String
renderReasons = unwords . map render . take 3 . sortOn (negate . snd)
  where
    render (r, n) = show n <> "x " <> r <> ";"

accuracy :: String -> Int -> Int -> IO ()
accuracy pid seed evals = case getProblem pid of
  Just (MkProblem bench) -> do
    (train, _) <- loadTrainAndTestSet "./" bench
    let cfg = (makeConfig train bench) {_nEvaluations = evals}
        pop = evalState (runEvolution cfg) (mkStdGen seed)
    putStrLn $ pid ++ " seed=" ++ show seed ++ " best=" ++ logFitness (_fitness (bestIndividual pop))
  Nothing -> putStrLn $ "unknown problem: " ++ pid
