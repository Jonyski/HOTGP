{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Module      : Benchmark.Gpu
--   Description : Scoring a whole population as one batch, in one place.
--
-- Why a batch
-- -----------
-- A GPU evaluates thousands of (program, case) pairs per launch at roughly
-- constant cost: what you pay for is the launch and the transfer, not the
-- arithmetic. HOTGP's steady-state loop scores /two/ children per step, which
-- is three orders of magnitude too small to amortise that (the arithmetic is
-- in @GPU.md@). The one place a batch already exists in the current engine is
-- the initial population: @popSize@ trees x @trainCases@ cases, e.g.
-- 1000 x 50 = 50 000 evaluations in one go. That is the same shape Beagle
-- uses per generation.
--
-- So this module exposes population-level scoring:
--
-- * 'scorePopulation' takes many trees, flattens the ones it can
--   ('Grammar.Flat'), evaluates them as a batch and aggregates each tree's
--   per-case results into a fitness - identical to
--   'Benchmark.BenchmarkToConfig.datasetFitness', which it shares the
--   aggregation with;
-- * trees that cannot be flattened (they use lists, strings, pairs or
--   lambdas) are scored by the ordinary interpreter, so the function is total
--   over any population and its result never depends on which side of the
--   split a tree landed on.
--
-- Backends
-- --------
-- 'CpuReference' runs 'Grammar.Flat.evalFlat' in-process. 'ExternalRunner'
-- hands the batch to a separate executable over the wire format in
-- "Benchmark.Gpu.Protocol" - the CUDA runner in @/gpu@. Running it as a
-- subprocess keeps the GPU code entirely out of the Haskell build (no FFI
-- stub libraries, no linker flags, no @nvcc@ dependency) and one process per
-- generation is negligible next to a kernel launch. @GPU.md@ discusses the
-- trade-off; the short version is that FFI becomes attractive only once the
-- loop scores batches per /step/.
module Benchmark.Gpu
  ( -- * Problems and backends
    Backend (..),
    ScoringProblem (..),
    problemFromBenchmark,
    BatchStats (..),

    -- * Batch scoring
    scorePopulation,
    populationBatch,
    eligibleCount,

    -- * Wiring into the run loop
    BatchScorer (..),
    mkBatchScorer,

    -- * The external runner
    runExternalRunner,
  )
where

import Benchmark.BenchmarkToConfig (outputsFitness)
import Benchmark.Core (Benchmark (..))
import Benchmark.Dataset (Dataset)
import Benchmark.Gpu.Protocol (decodeOutputs, encodeBatch)
import Benchmark.Helpers (Result)
import Control.Exception (IOException, catch, finally)
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Evolution.Fitness (Fitness)
import Evolution.Individual (Individual (MkIndividual))
import Grammar (Lit, Tree, computeMeasure, evalTree)
import Grammar.Flat (FlatProgram, evalFlat, flattenTree)
import System.Directory (getTemporaryDirectory, removeFile)
import System.Exit (ExitCode (ExitSuccess))
import System.IO (hClose, openTempFile)
import System.Process (readProcessWithExitCode)

-- | Where the batch is executed.
data Backend
  = -- | In-process, on the CPU ('Grammar.Flat.evalFlat'). Always available.
    CpuReference
  | -- | An external runner executable that speaks
    -- "Benchmark.Gpu.Protocol" (the CUDA runner, or the CPU simulator in
    -- @gpu/gp_eval_cpu.cpp@ used to verify it).
    ExternalRunner FilePath
  deriving (Eq, Show)

-- | Everything the batched evaluator needs from a problem: its arity, its
-- metric and its training cases.
--
-- This is deliberately not a 'Evolution.Config': the config hides the metric
-- behind @_fitnessFunction :: Tree -> a@, and a batch evaluator needs the
-- metric itself to turn per-case outputs into a score.
data ScoringProblem a = MkScoringProblem
  { _scoringArgCount :: !Int,
    _scoringMetric :: Lit -> Lit -> a,
    _scoringCases :: Dataset
  }

-- | Builds a 'ScoringProblem' from a benchmark and its training set.
problemFromBenchmark :: Benchmark a -> Dataset -> ScoringProblem a
problemFromBenchmark bench trainSet =
  MkScoringProblem
    { _scoringArgCount = length (_inputTypes bench),
      _scoringMetric = _fitnessMetric bench,
      _scoringCases = trainSet
    }

-- | What a batch actually did, for logging and for the coverage tables in
-- @GPU.md@.
data BatchStats = MkBatchStats
  { -- | Trees handed to the batch.
    _statTrees :: !Int,
    -- | How many of them could be flattened (the rest fell back to the
    -- interpreter).
    _statEligible :: !Int,
    -- | How many (program, case) evaluations the flattened part performed.
    _statBatchEvaluations :: !Int
  }
  deriving (Show, Eq)

-- | Batching is additive: one batch follows another.
instance Semigroup BatchStats where
  MkBatchStats t e b <> MkBatchStats t' e' b' = MkBatchStats (t + t') (e + e') (b + b')

instance Monoid BatchStats where
  mempty = MkBatchStats 0 0 0

-- | A reusable, stateful scorer: the shape 'Evolution.Run.runAndLogWith'
-- expects for the initial population.
--
-- It exists so the run loop does not have to know about flattening, batching
-- or CUDA: it just asks for 'Individual's. The accumulator ('_scorerStats')
-- sums every batch handed to it, which is what the run reports at the end.
data BatchScorer a = MkBatchScorer
  { -- | Scores these trees, in order.
    _scoreTrees :: [Tree] -> IO [Individual (Result a)],
    -- | Everything scored so far (all batches).
    _scorerStats :: IO BatchStats,
    -- | Which backend this scorer uses, for logging.
    _scorerBackend :: Backend
  }

-- | Builds a 'BatchScorer' for one problem and its training set.
--
-- The backend is chosen once, when the scorer is created, so a run that falls
-- back on the interpreter (unflattenable trees) still sends everything it
-- /can/ flatten to the same place for the whole run.
mkBatchScorer :: (Monoid a, Fitness a) => Backend -> Benchmark a -> Dataset -> IO (BatchScorer a)
mkBatchScorer backend bench trainSet = do
  acc <- newIORef mempty
  let problem = problemFromBenchmark bench trainSet
  pure
    MkBatchScorer
      { _scoreTrees = \trees -> do
          (individuals, stats) <- populationBatch backend problem trees
          modifyIORef' acc (<> stats)
          pure individuals,
        _scorerStats = readIORef acc,
        _scorerBackend = backend
      }

-- | Scores every tree in a population, returning one fitness per tree, in the
-- same order.
--
-- The aggregation is 'outputsFitness', the single implementation shared with
-- the normal interpreter path, so the result is bit-for-bit what
-- @_fitnessFunction@ would have produced for the same tree. That property is
-- what makes the initial population scored here interchangeable with one
-- scored by 'Evolution.Run.initPop', and it is asserted in @test/GpuSpec.hs@.
scorePopulation ::
  (Monoid a) =>
  Backend ->
  ScoringProblem a ->
  [Tree] ->
  IO ([Result a], BatchStats)
scorePopulation backend problem trees = do
  let nArgs = _scoringArgCount problem
      flats = map (flattenTree nArgs) trees
      -- Programs the kernel can run, in population order.
      eligible = [p | Right p <- flats]
      batchEvals = length eligible * length cases
      stats =
        MkBatchStats
          { _statTrees = length trees,
            _statEligible = length eligible,
            _statBatchEvaluations = batchEvals
          }

  batchOutputs <- case backend of
    CpuReference -> pure [map (evalFlat prog) cases | prog <- eligible]
    ExternalRunner exe -> runExternalRunner exe (encodeBatch eligible cases)

  -- Interleave: eligible trees consume the batch results in order, the rest
  -- are evaluated by the interpreter exactly as the serial path would.
  let outputsPerTree = attach (zip trees flats) batchOutputs
      results = [outputsFitness (_scoringMetric problem) (_scoringCases problem) outs | outs <- outputsPerTree]
  pure (results, stats)
  where
    cases = map fst (_scoringCases problem)

    attach _ [] = []
    attach [] _ = []
    attach ((tree, Left _) : rest) batch = map (\args -> evalTree args tree) cases : attach rest batch
    attach ((_, Right _) : rest) (outs : batch) = outs : attach rest batch

-- | 'scorePopulation' plus the wrapping into 'Individual's, ready to be put
-- into a 'Evolution.Individual.SortedPop'.
--
-- Trees are measured first ('Grammar.Helpers.computeMeasure'), because every
-- downstream consumer (depth limits, tie-breaking, logging) expects a valid
-- measure cache, exactly like 'Evolution.Individual.mkIndividual' does.
populationBatch ::
  (Fitness a, Monoid a) =>
  Backend ->
  ScoringProblem a ->
  [Tree] ->
  IO ([Individual (Result a)], BatchStats)
populationBatch backend problem trees = do
  (fitnesses, stats) <- scorePopulation backend problem trees
  let individuals =
        [ MkIndividual (computeMeasure tree) fit
          | (tree, fit) <- zip trees fitnesses
        ]
  pure (individuals, stats)

-- | How many of these trees can be handed to a kernel, and how many cannot
-- (with the flattening error of each, for the coverage report).
eligibleCount ::
  -- | Program arity.
  Int ->
  [Tree] ->
  (Int, [(String, Int)])
eligibleCount nArgs trees = (length rights, histogram lefts)
  where
    (lefts, rights) = partitionEithers' (map (flattenTree nArgs) trees)
    -- Collapse the messages so the report reads as a ranking of reasons
    -- ("list operation", "non-scalar literal", ...) rather than one line per
    -- tree. The messages carry the offending operation, so group by keyword.
    histogram = foldr bump []
    bump reason acc = case break ((== headline reason) . fst) acc of
      (before, (r, n) : after) -> before <> ((r, n + 1) : after)
      (before, []) -> before <> [(headline reason, 1)]
    headline msg
      | "is not in the GPU subset" `isInfixOf` msg = "operation outside the scalar subset"
      | "non-scalar literal" `isInfixOf` msg = "non-scalar literal"
      | otherwise = msg

    partitionEithers' = foldr step ([], [])
      where
        step (Left e) (es, rs) = (e : es, rs)
        step (Right r) (es, rs) = (es, r : rs)

-- | Sends a batch to an external runner and returns the decoded results.
--
-- Files rather than pipes: a batch is hundreds of kilobytes, and writing two
-- temp files avoids any chance of the two processes deadlocking on a full
-- pipe buffer. Both files are removed even if the runner fails.
runExternalRunner :: FilePath -> BL.ByteString -> IO [[Maybe Lit]]
runExternalRunner exe request = do
  tmp <- getTemporaryDirectory
  (reqPath, reqH) <- openTempFile tmp "hotgp-batch.hgb"
  (outPath, outH) <- openTempFile tmp "hotgp-batch.hgx"
  hClose outH
  let cleanup = removeFile reqPath >> removeFile outPath
  (do
      -- Strict write: the whole request is small enough to fit in memory and
      -- the runner expects a complete file.
      BS.hPut reqH (BL.toStrict request)
      hClose reqH
      -- A missing or non-executable runner is a setup mistake, and the
      -- default OS error ("posix_spawnp: does not exist") does not say what
      -- to do about it.
      (code, _stdout, stderrOut) <-
        readProcessWithExitCode exe [reqPath, outPath] ""
          `catch` \(e :: IOException) ->
            ioError . userError $
              "cannot run the GPU batch runner "
                <> show exe
                <> ": "
                <> show e
                <> "\nBuild it with `make -C gpu`, or set HOTGP_GPU_RUNNER to a runner executable."
      case code of
        ExitSuccess -> do
          raw <- BS.readFile outPath
          either (ioError . userError . ("GPU runner returned an invalid batch: " <>)) pure (decodeOutputs raw)
        other -> ioError $ userError $ "GPU runner " <> show exe <> " failed (" <> show other <> "): " <> stderrOut
    )
    `finally` cleanup
