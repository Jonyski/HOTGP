{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE StandaloneDeriving #-}

-- |
-- Module      : Evolution.Checkpoint
-- Description : Save/restore the run state so long benchmarks can be resumed.
--
-- A checkpoint is everything needed to continue a run exactly where it
-- stopped:
--
-- * the population (as plain 'Tree's - fitness is recomputed on load rather
--   than stored, which keeps the file format independent of the fitness
--   type);
-- * the evaluation count so far;
-- * the RNG state, so the resumed run draws the same random numbers the
--   interrupted one would have.
--
-- Serialisation uses the @flat@ library (a compact binary format) because
-- populations are large and JSON/text would be orders of magnitude slower
-- and bigger. Every grammar type gets a derived 'Flat' instance below.
--
-- The file is rewritten in place at a fixed cadence (every 1000
-- evaluations, see 'Evolution.Run.runAndLog'), so there is only ever one
-- checkpoint file per (seed, benchmark) pair.

module Evolution.Checkpoint (doesCheckpointExist, loadCheckpoint, saveCheckpoint) where

import qualified Control.Monad.State.Strict as S
import qualified Data.ByteString as B
import Data.Either (fromRight)
import qualified Data.SortedList as SL
import Data.Word (Word64)
import Evolution.Config (Config)
import Evolution.Core (St)
import Evolution.Fitness
import Evolution.Helpers (hoistState)
import Evolution.Individual
import Flat
import GHC.Generics (Generic)
import Grammar
import System.Directory (doesFileExist, removeFile)
import System.Random.Internal (StdGen (..), unStdGen)
import System.Random.SplitMix (seedSMGen', unseedSMGen)

-- | The on-disk representation of a run's state.
data Checkpoint = MkCheckpoint
  { _gen :: (Word64, Word64), -- the SplitMix generator's two words
    _population :: [Tree],
    _currentEvals :: Int
  }
  deriving (Show, Read, Generic, Flat)

-- * Flat instances for everything reachable from 'Checkpoint'.
--
-- These are mechanical: the binary format simply follows the constructors
-- defined in "Grammar.Core". They must be declared here (rather than next
-- to the types) because orphan instances would be required otherwise -
-- "Grammar" deliberately does not depend on @flat@.

deriving instance Flat TypedTree

deriving instance Flat Operation

deriving instance Flat FunctionType

deriving instance Flat GType

deriving instance Flat Lit

deriving instance Flat Terminal

deriving instance Flat Measure

deriving instance Flat Tree

type CheckpointFilename = FilePath

-- | Snapshots the current population and RNG into a 'Checkpoint'.
--
-- The generator is unpacked with 'unseedSMGen' into two 'Word64's because
-- that is how SplitMix represents its state, and a plain pair serialises
-- trivially.
makeCheckpoint :: Int -> SortedPop a -> St Checkpoint
makeCheckpoint nEvals pop = do
  gen <- S.gets unStdGen
  return $
    MkCheckpoint
      { _gen = unseedSMGen gen,
        _population = _indTree <$> SL.fromSortedList pop,
        _currentEvals = nEvals
      }

-- | Restores state from a 'Checkpoint': puts the RNG back, re-scores each
-- stored tree with the config's fitness function, and returns the eval
-- count with the rebuilt population.
--
-- Recomputing fitness (instead of reading it back) means a checkpoint stays
-- valid even if the fitness function or its tolerance changes between runs.
decodeCheckpoint :: (Fitness a) => Config a -> Checkpoint -> St (Int, SortedPop a)
decodeCheckpoint cfg checkpoint = do
  S.put (StdGen $ seedSMGen' $ _gen checkpoint)
  return (_currentEvals checkpoint, SL.toSortedList $ mkIndividual cfg <$> _population checkpoint)

-- | Does a checkpoint file exist at this path?
doesCheckpointExist :: CheckpointFilename -> S.StateT StdGen IO Bool
doesCheckpointExist = S.liftIO . doesFileExist

-- | Reads and decodes a checkpoint file.
--
-- A corrupt file is a hard error: silently starting over would throw away
-- hours of computation without telling the user.
loadCheckpoint :: (Fitness a) => Config a -> CheckpointFilename -> S.StateT StdGen IO (Int, SortedPop a)
loadCheckpoint cfg filename = do
  contents <- S.liftIO $ B.readFile filename
  hoistState $ decodeCheckpoint cfg $ fromRight (error $ "Invalid checkpoint in " <> filename) $ unflat contents

-- | Serialises the current state to disk (overwriting any previous
-- checkpoint for this run).
saveCheckpoint :: (Fitness a) => CheckpointFilename -> Int -> SortedPop a -> S.StateT StdGen IO ()
saveCheckpoint filename nEvals pop = do
  checkpoint <- hoistState $ makeCheckpoint nEvals pop
  S.liftIO $ B.writeFile filename $ flat checkpoint
