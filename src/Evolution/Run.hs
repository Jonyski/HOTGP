{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : Evolution.Run
-- Description : The evolutionary loop: init -> (sample, breed, mutate, replace)*
--
-- This module owns the search's control flow. The algorithm is
-- /steady-state/ genetic programming rather than the classic generational
-- model:
--
-- * the population is never replaced wholesale;
-- * each iteration (\"step\") samples a handful of parents, breeds children,
--   and merges the children back into the population, keeping only the best
--   'Evolution.Config._popSize' individuals ('keepBest').
--
-- That keeps the best solution found so far alive forever (elitism by
-- construction) and makes the evaluation count increase smoothly, which is
-- convenient for checkpointing and for plotting fitness over budget.
--
-- The loop stops when either
--
-- * a perfect solution is found ('Evolution.Fitness.isPerfectSolution'), or
-- * the evaluation budget 'Evolution.Config._nEvaluations' is exhausted.
--
-- Persistence
-- -----------
-- 'runAndLog' wraps the loop with checkpointing: every 1000 evaluations the
-- population and RNG state are written to disk, and a restart resumes from
-- the last checkpoint instead of starting over. This is what makes long
-- benchmark runs interruptible.

module Evolution.Run (runAndLog, runEvolution, Individual (_indTree, _fitness)) where

import Control.Monad (replicateM, when)
import Control.Monad.State.Strict (get, gets, put)
import qualified Control.Monad.State.Strict as S
import Data.List (find, foldl')
import Data.Maybe (fromJust)
import qualified Data.SortedList as SL
import Data.Time (UTCTime, getCurrentTime)
import Evolution.Checkpoint
import Evolution.Config
import Evolution.Core (St)
import Evolution.Crossover (crossOver)
import Evolution.Fitness (Fitness (isPerfectSolution))
import Evolution.Generate (ramped)
import Evolution.Helpers (hoistState, randomR, tupleToList)
import Evolution.Individual
import Evolution.Mutation (mutate)
import Grammar (FunctionType (_argTypes), Tree, computeMeasure, getHeight)
import Pretty (Pretty (pretty))
import System.IO (hFlush, stdout)
import System.Random.Internal (StdGen)
import Text.Printf

-- | How a caller reports progress: given the previous log cache (if any),
-- the current time, the evaluation count and the population, produce a new
-- cache and perform the logging in IO.
--
-- Supplied by the benchmark layer ("Benchmark.Run") so this module does not
-- need to know about CSV files or test sets.
type LoggingFunction s a = (Maybe s -> UTCTime -> Evaluations -> SortedPop a -> IO s)

-- | Runs the evolution with the given config.
--
-- This is the entry point used by the benchmarks. It
--
-- 1. checks for an existing checkpoint and resumes it if present, otherwise
--    builds an initial population with 'ramped';
-- 2. loops 'steadyStateReplace' until a perfect solution appears or the
--    evaluation budget runs out;
-- 3. saves a checkpoint every 1000 evaluations;
-- 4. prints progress (timestamp + evaluations done) to stdout.
--
-- The generator lives in the @StateT StdGen IO@ stack: IO for logging and
-- file access, state for reproducible randomness ('Evolution.Helpers.hoistState'
-- moves pure computations between the two).
runAndLog :: (Show a, Fitness a) => Config a -> LoggingFunction s a -> FilePath -> S.StateT StdGen IO (SortedPop a, Int)
runAndLog cfg loggingFunction checkpointFilename = do
  hasCheckpoint <- doesCheckpointExist checkpointFilename
  if hasCheckpoint
    then resumeFromCheckpoint
    else startFromScratch
  where
    checkpointEvery = 1000
    resumeFromCheckpoint = do
      S.liftIO $ putStrLn "LOADING CHECKPOINT"
      S.liftIO $ hFlush stdout
      -- Restores both the population and the RNG state, so the resumed run
      -- continues the same random sequence as the interrupted one.
      (evals, pop) <- loadCheckpoint cfg checkpointFilename
      go Nothing evals pop
    startFromScratch = do
      S.liftIO $ putStrLn "STARTING FROM SCRATCH"
      S.liftIO $ hFlush stdout
      p <- hoistState $ initPop cfg
      time <- S.liftIO getCurrentTime
      -- statsCache <- S.liftIO $ loggingFunction Nothing time (length p) p
      S.liftIO $ putStrLn $ show time <> " -\t" <> show (length p) <> "/" <> show (_nEvaluations cfg)
      -- go (Just statsCache) (length p) p
      go Nothing (length p) p
    -- Main Loop:
    -- nEvals counts every evaluation spent so far (including the initial
    -- population); pop is the current (sorted) population.
    go maybeStatsCache nEvals pop = do
      when (nEvals `mod` checkpointEvery == 0) $ do
        S.liftIO $ putStrLn ":: CHECKPOINT ::"
        saveCheckpoint checkpointFilename nEvals pop

      (innerNEvals, newPop) <- hoistState $ steadyStateReplace cfg pop
      let totalNEvals = innerNEvals + nEvals
          pct :: Float
          pct = 100.0 * fromIntegral totalNEvals / fromIntegral (_nEvaluations cfg)
      time <- S.liftIO getCurrentTime
      -- newStatsCache <- S.liftIO $ loggingFunction maybeStatsCache time totalNEvals newPop
      S.liftIO $ printf "%s\t%d/%d (%.2f%%)\n" (show time) totalNEvals (_nEvaluations cfg) pct

      if isPerfectSolution (_fitness $ bestIndividual newPop)
        then do
          S.liftIO $ putStrLn $ show time <> " -\t" <> "Perfect solution found! " <> pretty (_indTree $ bestIndividual newPop)
          return (newPop, totalNEvals)
        else
          if totalNEvals >= _nEvaluations cfg
            then return (newPop, totalNEvals) -- DONE
            -- else go (Just newStatsCache) totalNEvals newPop
            else go Nothing totalNEvals newPop

-- | Runs the evolution with the given config.
--
-- The /pure/ version of the loop: no logging, no checkpointing, just the
-- algorithm in the 'St' monad. Handy for tests and for experiments that
-- only care about the final population.
runEvolution :: (Fitness a) => Config a -> St (SortedPop a)
runEvolution cfg = do
  p <- initPop cfg
  go (length p) p
  where
    go nEvals pop = do
      (innerNEvals, newPop) <- steadyStateReplace cfg pop
      let totalNEvals = innerNEvals + nEvals
      if totalNEvals >= _nEvaluations cfg
        then return newPop
        else go totalNEvals newPop

-- | Creates the initial population with the config.
--
-- 'ramped' produces the trees; each is scored once, which is why the
-- initial population already costs @popSize@ evaluations.
initPop :: (Fitness a) => Config a -> St (SortedPop a)
initPop cfg = SL.toSortedList . map (mkIndividual cfg) <$> ramped cfg

-- | Runs the step of the evolution, known as Steady State Replace.
--
-- One step, in order:
--
-- 1. rank the population exponentially by fitness ('exponentialRank') and
--    sample _individualsPerStep_ parents, so better individuals breed more
--    often;
-- 2. pair them up and apply crossover with probability _crossoverRate_
--    ('doCrossover');
-- 3. apply mutation to each child with the complementary probability
--    ('doMutation');
-- 4. drop children that are exact duplicates of an existing individual
--    (evaluating them again would be wasted budget);
-- 5. merge the survivors with the old population and keep the best
--    _popSize_ ('keepBest').
--
-- Returns the number of evaluations the step consumed and the new
-- population.
steadyStateReplace :: (Fitness a) => Config a -> SortedPop a -> St (Evaluations, SortedPop a)
steadyStateReplace cfg pop = do
  let rankedPop = exponentialRank cfg pop
  parents <- inPairs . map _indTree <$> sampleManyWithProb (_individualsPerStep cfg) rankedPop
  children <- concat <$> mapM (doCrossover cfg) parents
  xMen <- mapM (doMutation cfg) children

  let popTrees = map _indTree $ SL.fromSortedList pop
      withoutDuplication = filter (`notElem` popTrees) xMen
      evaluations = length children -- withoutDuplication
      newPop = keepBest cfg pop $ mkIndividual cfg <$> withoutDuplication
  return (evaluations, newPop)

-- | Given a probability, runs an action or uses a fallback.
--
-- The coin flip is the standard way genetic operators are gated: the
-- operator either applies or the individual passes through unchanged.
tossCoin :: Double -> a -> St a -> St a
tossCoin prob fallback action = do
  toss <- (< prob) <$> (randomR (0, 1) :: St Double)
  if not toss
    then return fallback
    else action

-- | Tosses a coin and applies the crossover.
--
-- With probability _crossoverRate_ the parents are crossed; otherwise the
-- pair is passed through unchanged (and therefore costs no evaluation - the
-- caller only scores what actually came back as new trees).
--
-- 'computeMeasure' is applied to the results because a spliced subtree
-- invalidates the depth/height cache of every ancestor.
doCrossover :: Config a -> (Tree, Tree) -> St [Tree]
doCrossover cfg parents =
  tossCoin (_crossoverRate cfg) (tupleToList parents) $ maybe [] (map computeMeasure . tupleToList) <$> uncurry (crossOver cfg) parents

-- | Tosses a coin and applies the mutation.
--
-- Uses @1 - _crossoverRate@ as its probability, so the two operators
-- complement each other: a child that was not crossed over is likely to be
-- mutated, and vice versa.
doMutation :: Ord a => Config a -> Tree -> St Tree
doMutation cfg tree = tossCoin (1 - _crossoverRate cfg) tree $ mutate cfg tree

-- | Ranks a population and gives them probabilities with an exponential falloff.
--
-- The population is already sorted best-first, so rank @i@ (0-based) gets
-- weight @\_parentScalar ** i@. Those weights are normalised by
-- 'sampleManyWithProb'. This is fitness-proportionate selection expressed
-- through ranks, which is robust to fitnesses of wildly different scales
-- (only the order matters).
exponentialRank :: Config a -> SortedPop a -> [(Individual a, Double)]
exponentialRank cfg ps = zip (SL.fromSortedList ps) $ (_parentScalar cfg **) <$> [0 ..]

-- * Survivor selection strategies

-- | Keep only the best individuals, regardless if they were parent or child.
--
-- The strategy actually used by the loop: parents and children are pooled
-- and the top _popSize_ survive. Combined with the sorted population this
-- is pure elitism - a better individual can never be dropped.
keepBest :: (Ord a) => Config a -> SortedPop a -> [Individual a] -> SortedPop a
keepBest cfg oldPop children = SL.take (_popSize cfg) $ oldPop <> SL.toSortedList children

-- | Keep all of the children, always replacing the worst parents.
--
-- An alternative (more aggressive) survivor strategy that is defined here
-- for experimentation but not currently wired into the main loop.
replaceWorst :: (Ord a) => Config a -> SortedPop a -> [Individual a] -> SortedPop a
replaceWorst cfg oldPop children = SL.toSortedList children <> SL.take (_popSize cfg - length children) oldPop

-- * Helpers

-- | Gets the list elements in pairs.
--
-- Drops a trailing odd element: with an odd number of sampled parents the
-- last one simply does not breed this step.
inPairs :: [a] -> [(a, a)]
inPairs (x1 : (x2 : xs)) = (x1, x2) : inPairs xs
inPairs _ = []

-- | Samples values with a given probability for each value.
--
-- This is roulette-wheel selection over arbitrary (unnormalised) weights:
-- accumulate the weights into a cumulative-sum \"wheel\", draw a uniform
-- number in @[0, total]@, and take the first entry whose cumulative
-- threshold exceeds the draw. Weights do not need to sum to 1 - only their
-- ratios matter.
sampleManyWithProb ::
  -- | How many values to sample
  Int ->
  -- | Each possible value paired with their probability, not necessarily normalized
  [(a, Double)] ->
  St [a]
sampleManyWithProb n xs = replicateM n sampleWithProb
  where
    (max, roulette) = cumSum xs
    sampleWithProb = do
      rand <- randomR (0, max)
      return $ fst . fromJust $ find ((> rand) . snd) roulette
    cumSum :: [(a, Double)] -> (Double, [(a, Double)])
    cumSum = fmap reverse . foldl' cumSumReducer (0, [])
      where
        cumSumReducer :: (Double, [(a, Double)]) -> (a, Double) -> (Double, [(a, Double)])
        cumSumReducer (acc, xs) (x, prob) = (newAcc, (x, newAcc) : xs)
          where
            newAcc = prob + acc
