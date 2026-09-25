-- |
-- Module      : MeasureSpec
-- Description : The cached tree measure (depth / height / node count).
--
-- Every 'Tree' carries a lazily-computed 'MkMeasure' (see
-- 'Grammar.Helpers.computeMeasure') that evolution relies on for depth
-- limits, parsimony tie-breaks and logging. This is a small, exact-value
-- (HUnit, not QuickCheck) sanity check: a leaf measures 0/0/1, and the
-- reference trees from "ProblemTrees" have the heights and sizes you get by
-- counting them by hand.
module MeasureSpec where

import Data.Maybe (fromJust)
import Grammar
import Grammar.Helpers (computeMeasure)
import Pretty
import ProblemTrees
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

-- | Four fixed cases: one argument leaf, one literal leaf, and two
-- reference trees of increasing size.
tests :: [TestTree]
tests =
  [ testCase "Leaf Arg" $
      getMeasure (LeafArg 0)
        @?= ( MkMeasure
                { _currentDepth = 0,
                  _height = 0,
                  _nodeCount = 1
                }
            ),
    testCase "Leaf Lit" $
      getMeasure (iLitT 0)
        @?= ( MkMeasure
                { _currentDepth = 0,
                  _height = 0,
                  _nodeCount = 1
                }
            ),
    testCase "Number IO" $
      getMeasure numberIOTree
        @?= ( MkMeasure
                { _currentDepth = 0,
                  _height = 2,
                  _nodeCount = 4
                }
            ),
    testCase "Small Or Large" $
      getMeasure smallOrLargeTree
        @?= ( MkMeasure
                { _currentDepth = 0,
                  _height = 3,
                  _nodeCount = 11
                }
            )
  ]
