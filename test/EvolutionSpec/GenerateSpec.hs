-- |
-- Module      : EvolutionSpec.GenerateSpec
-- Description : Trees produced by the initial-population generators are
--               well-typed.
--
-- "Evolution.Generate" offers the classic Koza initialisation strategies:
--
-- * @full@ - grow every branch to exactly the max depth;
-- * @grow@ - stop early at random (may produce leaves before the limit);
-- * @ramped@ - mix of both, used to seed a population with varied sizes.
--
-- All three must emit trees that satisfy 'validTypedTree' (type-checks
-- against the program type and respects the depth limit), and a ramped
-- batch must be /internally consistent/: every tree in one initial
-- population has the same program type, otherwise crossover could never
-- pair them up.
module EvolutionSpec.GenerateSpec where

import Control.Monad.State.Strict (evalState)
import Evolution
import EvolutionSpec.Helpers
import Grammar
import Test.Tasty
import qualified Test.Tasty.QuickCheck as QC

-- | Four properties: full, grow, ramped validity, and ramped type
-- uniformity.
tests :: [TestTree]
tests =
  [ QC.testProperty "full" $ QC.forAll (arbitraryTree full) validTypedTree,
    QC.testProperty "grow" $ QC.forAll (arbitraryTree grow) validTypedTree,
    QC.testProperty "ramped" $
      QC.forAll arbitraryRamped $
        QC.conjoin . fmap validTypedTree,
    QC.testProperty "ramped are all same type" $
      QC.forAll arbitraryRamped $ \trees -> let types = _type . snd <$> trees in all (== head types) types
  ]
