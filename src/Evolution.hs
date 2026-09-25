-- |
-- Module      : Evolution
-- Description : Umbrella module re-exporting the GP engine.
--
-- Importing "Evolution" gives you everything needed to run a search:
--
-- * "Evolution.Config"    - the 'Config' record (all the run parameters);
-- * "Evolution.Core"      - the 'St' random monad and type aliases;
-- * "Evolution.Generate"  - initial population generation;
-- * "Evolution.Helpers"   - randomness and tree-position utilities;
-- * "Evolution.Mutation"  - the mutation operator;
-- * "Evolution.Pretty"    - population table printing;
-- * "Evolution.Run"       - 'runAndLog' / 'runEvolution', the main loops;
-- * "Evolution.SamplerTable" - the type-directed tree generator.
--
-- Not re-exported (import them directly if you need them):
-- "Evolution.Crossover" (used through 'Evolution.Run'), "Evolution.Checkpoint",
-- "Evolution.Fitness", and "Evolution.Individual" (only its '_indTree' and
-- '_fitness' selectors come through "Evolution.Run").
module Evolution
  ( module Evolution.Config,
    module Evolution.Core,
    module Evolution.Generate,
    module Evolution.Helpers,
    module Evolution.Mutation,
    module Evolution.Pretty,
    module Evolution.Run,
    module Evolution.SamplerTable,
  )
where

import Evolution.Config
import Evolution.Core
import Evolution.Generate
import Evolution.Helpers
import Evolution.Mutation
import Evolution.Pretty
import Evolution.Run
import Evolution.SamplerTable
