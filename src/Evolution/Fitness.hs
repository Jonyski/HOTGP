-- |
-- Module      : Evolution.Fitness
-- Description : The type class every score must satisfy, plus its instances.
--
-- In this project /lower is better/ for every fitness type: 0 (or a tiny
-- epsilon for floats) means \"perfect\". That convention is what makes
-- 'Ord' on 'Evolution.Individual.Individual' meaningful - the population is
-- sorted ascending and the head is the best candidate.
--
-- The class exists because the run loop needs two operations on a score
-- without knowing its concrete type:
--
-- * 'logFitness'  - how to write it to the CSV log;
-- * 'isPerfectSolution' - when to stop the search early.
--
-- Wrapper instances ('Result', 'Sum') let a problem pick whichever monoid
-- suits its metric (e.g. counting errors with 'Sum', or flagging a crashed
-- case with 'Result') while still being usable by the generic run loop.
module Evolution.Fitness where

import Benchmark.Helpers (Result (Error, Result))
import Data.Monoid (Sum (Sum, getSum))

-- | Values that can be used as fitness.
--
-- Superclass constraints: 'Ord' for ranking, 'Show'/'Read' for logging and
-- (de)serialisation.
class (Ord a, Show a, Read a) => Fitness a where
  -- | How to log this fitness in the csv.
  logFitness :: a -> String

  -- | Does this fitness represent a perfect solution?
  --
  -- Used to stop the run as soon as a solution is found, rather than
  -- burning the remaining evaluation budget.
  isPerfectSolution :: a -> Bool

-- | Fitness of a computation that may have crashed: a failed case can never
-- be \"perfect\", and it logs as @nan@ so downstream analysis can count
-- crashes separately from ordinary errors.
instance Fitness a => Fitness (Result a) where
  logFitness (Result x) = logFitness x
  logFitness Error = "nan"
  isPerfectSolution (Result x) = isPerfectSolution x
  isPerfectSolution Error = False

-- | Sums of fitnesses: perfect only if every component is perfect.
instance Fitness a => Fitness (Sum a) where
  logFitness = logFitness . getSum
  isPerfectSolution = isPerfectSolution . getSum

-- | Continuous metrics (e.g. mean squared error). 1e-3 is the tolerance:
-- exact 0 is unreachable when comparing floats.
instance Fitness Float where
  logFitness = show
  isPerfectSolution x = x < 1e-3

-- | Exact integer metrics (e.g. number of mismatching test cases): perfect
-- means no mismatches at all.
instance Fitness Int where
  logFitness = show
  isPerfectSolution x = x <= 0

-- | Same as 'Int', but for metrics that can exceed 32-bit range (used by
-- problems that sum large integer errors).
instance Fitness Integer where
  logFitness = show
  isPerfectSolution x = x <= 0