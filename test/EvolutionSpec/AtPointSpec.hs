-- |
-- Module      : EvolutionSpec.AtPointSpec
-- Description : The pre-order addressing scheme used by every operator.
--
-- Trees are addressed by a 'Point': the sequence of child indices leading
-- from the root to a node (@[2,1]@ = second child of the first child).
-- 'atPoint' applies an update at that address, and 'atRandomPoint' picks an
-- address uniformly - both are the foundation of mutation, crossover and
-- subtree pruning, so a numbering bug here would silently corrupt all of
-- them.
--
-- Two kinds of test:
--
-- * /Exact HUnit cases/ - small trees where every position's expected
--   result can be written down by hand (a literal replaced by @10@ at each
--   of 1..5).
-- * /A statistical QuickCheck property/ - call 'atRandomPoint' 1000 times
--   on a 5-node tree and require that (a) every possible result appears and
--   (b) each appears between 150 and 250 times, i.e. the sampling is
--   uniform within a generous tolerance (expected 200 each; the window is
--   ~3 standard deviations for n=1000).
module EvolutionSpec.AtPointSpec where

import Control.Monad (replicateM)
import Control.Monad.State.Strict (evalState)
import Data.Bifunctor (Bifunctor (first))
import Data.List
import Evolution
import EvolutionSpec.Helpers
import Grammar
import Pretty
import Test.Tasty
import Test.Tasty.HUnit
import qualified Test.Tasty.QuickCheck as QC

-- | The exact-addressing group plus the randomness property.
tests :: [TestTree]
tests =
  [ testGroup "At Point" atPointTests,
    atRandomPointTest
  ]

-- | @5 + 7@ - two children, positions 1..3.
exprTree :: Tree
exprTree = AddInt <| [iLitT 5, iLitT 7]

-- | @(1 + 2) * 3@ - the tree used for the 5-position cases and for the
-- randomness property.
exprTree2 :: Tree
exprTree2 = MultInt <| [AddInt <| [iLitT 1, iLitT 2], iLitT 3]

-- | Replace whatever sits at @point@ with the literal @10@, discarding the
-- state (the update function is pure, so the RNG state is never touched -
-- hence the dummy @undefined@).
replaceWith10 :: Point -> Tree -> Tree
replaceWith10 point tree =
  evalState (atPoint point (const $ return $ iLitT 10) tree) undefined

-- | The hand-written exact-position cases: root, both children of a binary
-- op, and all five positions of the nested tree.
atPointTests :: [TestTree]
atPointTests =
  [ testGroup
      "Only Root"
      [testCase "Updates position 1" $ replaceWith10 1 (iLitT 5) @?= iLitT 10],
    testGroup
      "Simple add"
      [ testCase "Updates position 1" $ replaceWith10 1 exprTree @?= iLitT 10,
        testCase "Updates position 2" $
          replaceWith10 2 exprTree @?= AddInt <| [iLitT 10, iLitT 7],
        testCase "Updates position 3" $
          replaceWith10 3 exprTree @?= AddInt <| [iLitT 5, iLitT 10]
      ],
    testGroup
      "Mult and Add"
      [ testCase "Updates position 1" $ replaceWith10 1 exprTree2 @?= iLitT 10,
        testCase "Updates position 2" $
          replaceWith10 2 exprTree2 @?= MultInt <| [iLitT 10, iLitT 3],
        testCase "Updates position 3" $
          replaceWith10 3 exprTree2
            @?= MultInt <| [AddInt <| [iLitT 10, iLitT 2], iLitT 3],
        testCase "Updates position 4" $
          replaceWith10 4 exprTree2
            @?= MultInt <| [AddInt <| [iLitT 1, iLitT 10], iLitT 3],
        testCase "Updates position 5" $
          replaceWith10 5 exprTree2
            @?= MultInt <| [AddInt <| [iLitT 1, iLitT 2], iLitT 10]
      ]
  ]

-- | Every outcome 'atRandomPoint' can produce on 'exprTree2' - the set the
-- property below requires to be hit completely.
possibleTrees :: [Tree]
possibleTrees =
  [ iLitT 10,
    MultInt <| [iLitT 10, iLitT 3],
    MultInt <| [AddInt <| [iLitT 10, iLitT 2], iLitT 3],
    MultInt <| [AddInt <| [iLitT 1, iLitT 10], iLitT 3],
    MultInt <| [AddInt <| [iLitT 1, iLitT 2], iLitT 10]
  ]

containSameElements :: Eq a => [a] -> [a] -> Bool
containSameElements l1 l2 = all (`elem` l1) l2 && all (`elem` l2) l1

countElements :: Eq a => [a] -> [(a, Int)]
countElements xs = map (\x -> (x, length . filter (== x) $ xs)) $ nub xs

-- | Uniformity property: 1000 samples must cover every position, with each
-- position hit roughly 200 times (accepted window: 150-250).
atRandomPointTest :: TestTree
atRandomPointTest = QC.testProperty "Nodes are picked uniformly at random" $
  do
    trees <-
      withRandomSeed $
        replicateM 1000 $
          atRandomPoint (const $ return $ iLitT 10) exprTree2
    let allAreRepresented =
          QC.counterexample (pretty . nub $ trees) $
            containSameElements trees possibleTrees
        counts = countElements trees
        allAreInAcceptableRange =
          QC.counterexample
            (show $ first pretty <$> counts)
            $ all (\x -> x > 150 && x < 250) $
              snd <$> counts
    return $ allAreRepresented QC..&&. allAreInAcceptableRange
