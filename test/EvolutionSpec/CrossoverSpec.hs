-- |
-- Module      : EvolutionSpec.CrossoverSpec
-- Description : Crossed-over children stay well-typed and within the depth
--               limit.
--
-- Crossover is the riskiest operator: splicing a subtree from one parent
-- into another can easily break typing or blow up the size. These two
-- properties are the regression net for "Evolution.Crossover":
--
-- 1. /TypeChecks/ - generate two parents of the same program type, cross
--    them (under a fixed seed, so the run is reproducible), and both
--    children must pass 'runTypeCheck'. A @Nothing@ result (no compatible
--    subtree was found, so crossover declined) is discarded - declining is
--    correct behaviour, returning an ill-typed child is not.
-- 2. /Never Exceed Depth/ - the same setup, now requiring both children's
--    heights to stay within '_maxTreeDepth'.
--
-- Parents are generated /small/ (@QC.resize 2@): with small trees most
-- random swaps are legal, so the properties actually get to check children
-- rather than discarding constantly.
module EvolutionSpec.CrossoverSpec where

import Evolution (Config (_maxTreeDepth))
import Evolution.Crossover
import EvolutionSpec.Helpers
import Grammar
import Pretty
import Test.Tasty
import qualified Test.Tasty.QuickCheck as QC

-- | The two properties above.
tests :: [TestTree]
tests =
  [ QC.testProperty "Crossover TypeChecks" crossoverTypeChecks,
    QC.testProperty "Crossover Never Exceed Depth" crossoverNeverExceedsDepth
  ]

-- | Property 1: both children of a crossover must type-check.
--
-- The counterexample prints the two parent trees, since that is the only
-- useful clue when a swap goes wrong.
crossoverTypeChecks :: QC.Gen QC.Property
crossoverTypeChecks = do
  argCount <- QC.choose (0, 5)
  fType <- QC.resize argCount QC.arbitrary
  (cfg, trees) <- QC.resize 2 $ arbitraryRampedOfTypeWithConfig fType
  let [(_, t1), (_, t2)] = trees
      tCheck t = runTypeCheck $ MkTypedTree t fType
  maybePair <- withRandomSeed $ crossOver cfg (_tree t1) (_tree t2)
  let p = maybe QC.discard (\(ta, tb) -> tCheck ta QC..&&. tCheck tb) maybePair
  return $
    QC.counterexample
      ( "Failed for crossover: \n\t"
          <> pretty (_tree t1)
          <> "\nWITH\n\t"
          <> pretty (_tree t2)
          <> "\n--------\n"
      )
      p

-- | Property 2: both children's height stays within '_maxTreeDepth'.
--
-- Parents are measured ('computeMeasure') before the swap because the fit
-- check reads the cached measure; the children are measured again by
-- 'getHeight'. The counterexample shows both children, the configured
-- limit and their measured heights.
crossoverNeverExceedsDepth :: QC.Gen QC.Property
crossoverNeverExceedsDepth = do
  argCount <- QC.choose (0, 5)
  fType <- QC.resize argCount QC.arbitrary
  (cfg, trees) <- QC.resize 2 $ arbitraryRampedOfTypeWithConfig fType
  let [(_, t1), (_, t2)] = trees
      isValid t = getHeight (computeMeasure t) <= _maxTreeDepth cfg
  maybePair <-
    withRandomSeed $
      crossOver
        cfg
        (computeMeasure $ _tree t1)
        (computeMeasure $ _tree t2)
  case maybePair of
    Nothing -> QC.discard
    Just (ta, tb) -> do
      let p = maybe QC.discard (\(ta, tb) -> isValid ta QC..&&. isValid tb) maybePair
      return $
        QC.counterexample
          ( unlines
              [ "Failed for crossover",
                "Max Depth " <> show (_maxTreeDepth cfg),
                pretty ta,
                "Height: " <> show (getHeight ta),
                "WITH",
                pretty tb,
                "Height: " <> show (getHeight tb),
                "--------",
                ""
              ]
          )
          p
