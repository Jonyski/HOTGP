-- |
-- Module      : Benchmark.Helpers
-- Description : Small shared utilities for benchmarks: Result, shuffles and
--               the \"relevant type\" combinators.
module Benchmark.Helpers where

import Control.Monad.State.Strict (MonadState (state))
import Data.List (intercalate)
import qualified Data.Map as M
import Evolution.Core (St)
import Grammar
import System.Random

-- | A 'Maybe' with an 'Ord' instance that puts failures /above/ every
-- success.
--
-- Fitness is \"smaller is better\", so @Error@ must sort as the /worst/
-- possible value - which is exactly what a derived 'Ord' gives when
-- 'Error' is the last constructor. 'Maybe' has no such guarantee for all
-- uses, and this type also carries a 'Monoid' that propagates errors (see
-- below), letting a fitness be the sum over test cases with any crash
-- poisoning the whole score.
data Result a = Result !a | Error deriving (Eq, Ord, Show, Read) -- custom Maybe datatype for custom Ord, where Error is greater than everything

-- | Convert a partial computation's result: a runtime failure becomes
-- 'Error' instead of an exception.
maybeToResult :: Maybe a -> Result a
maybeToResult Nothing = Error
maybeToResult (Just a) = Result a

-- | Combines two results, short-circuiting to 'Error' if either failed.
-- With 'mconcat' this scores a whole test suite as one value.
instance Semigroup a => Semigroup (Result a) where
  (Result x) <> (Result y) = Result $ x <> y
  _ <> _ = Error

instance Monoid a => Monoid (Result a) where
  mempty = Result mempty

instance Functor Result where
  fmap f (Result x) = Result (f x)
  fmap f Error = Error

-- | One step of the Fisher-Yates shuffle: swap the value at a random index
-- @j <= i@ with the one at @i@.
--
-- Folded over the whole map (see the callers in "Benchmark.Dataset"), it
-- produces a uniformly random permutation. Keeping it as a fold over a
-- 'M.Map' avoids copying lists at each step.
fisherYatesStep :: RandomGen g => (M.Map Int a, g) -> (Int, a) -> (M.Map Int a, g)
fisherYatesStep (m, gen) (i, x) = ((M.insert j x . M.insert i (m M.! j)) m, gen')
  where
    (j, gen') = randomR (0, i) gen

-- | Also allow lists of the given types.
--
-- A benchmark declares the types it considers \"interesting\"; these
-- combinators expand that set with the derived container forms the grammar
-- may use, so a problem can opt into lists/pairs/lambdas in one line.
allowList :: [GType] -> [GType]
allowList gTypes = gTypes <> (GList <$> gTypes)

-- | Also allow pairs built from the given types.
allowPairs :: [GType] -> [GType]
allowPairs gTypes = gTypes <> (GPair <$> gTypes <*> gTypes)

-- | Also allow unary functions @t -> t@ over the given types - i.e. enable
-- higher-order operations such as @map@ and @filter@ with those types.
allowUnaryLambdas :: [GType] -> [GType]
allowUnaryLambdas gTypes = gTypes <> (GLambda <$> (MkFunctionType <$> ((: []) <$> gTypes) <*> gTypes))

-- | Join CSV cells with semicolons (the datasets use ';', not ',',
-- because inputs may contain commas).
csvJoin :: [String] -> String
csvJoin = intercalate ";"