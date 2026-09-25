-- |
-- Module      : Grammar.Helpers
-- Description : Smart constructors, literal builders and the tree "measure" cache.
--
-- Two kinds of helpers live here:
--
-- 1. /Construction shorthands/ - tiny wrappers that make tree literals
--    readable. Writing @iLitT 5@ is nicer than
--    @Leaf Nothing (Literal (IntLit 5))@, and the tests/problem definitions
--    are full of them.
--
-- 2. /The measure cache/ - 'computeMeasure' annotates every node of a tree
--    with its depth, height and node count; 'getHeight' & friends read the
--    cache back (computing it on demand if missing). See the note on
--    'Measure' in "Grammar.Core" for why this is memoised: these numbers are
--    queried constantly during evolution.
module Grammar.Helpers where

import Data.Maybe (fromJust)
import Grammar.Core
import Grammar.Types (litType)

-- * Smart constructors

-- | A leaf carrying the given terminal, with no measure yet.
mkLeaf :: Terminal -> Tree
mkLeaf = Leaf Nothing

-- | A leaf holding a literal value.
litT :: Lit -> Tree
litT = LeafLit

-- | A leaf referring to the n-th argument (@$n@).
arg :: Int -> Tree
arg = LeafArg

-- * Literal builders
--
-- @stLit@, @pairLit@, @listLitOf@... build 'Lit' values; the @...T@ variants
-- go one step further and wrap them in a leaf, ready to splice into a tree.

-- | A Haskell 'String' as a literal: a list of 'CharLit'.
stLit :: String -> Lit
stLit = tListLitOf GChar CharLit

pairLit :: (Lit, Lit) -> Lit
pairLit (a, b) = PairLit a b

-- | Build a lambda literal from a body and its signature.
lambdaLit :: Tree -> FunctionType -> Lit
lambdaLit a b = LambdaLit $ MkTypedTree a b

-- | A list literal whose element type is inferred from the converter.
--
-- Partial on the empty list (it needs at least one element to inspect); use
-- 'tListLitOf' when the list may be empty.
listLitOf :: (a -> Lit) -> [a] -> Lit
listLitOf f xs = tListLitOf t f xs
  where
    t = litType $ f (head xs)

-- | A list literal with an explicitly given element type.
tListLitOf :: GType -> (a -> Lit) -> [a] -> Lit
tListLitOf t f xs = ListLit t $ map f xs

-- | Integer literal leaf.
iLitT :: Int -> Tree
iLitT = litT . IntLit

-- | Float literal leaf.
fLitT :: Float -> Tree
fLitT = litT . FloatLit

-- | Bool literal leaf.
bLitT :: Bool -> Tree
bLitT = litT . BoolLit

-- | Char literal leaf.
chLitT :: Char -> Tree
chLitT = litT . CharLit

-- | String literal leaf (a list of chars).
stLitT :: String -> Tree
stLitT = litT . stLit

pairLitT :: (Lit, Lit) -> Tree
pairLitT = litT . pairLit

-- | Lambda literal leaf: a function value inside a tree.
lambdaLitT :: Tree -> FunctionType -> Tree
lambdaLitT a b = litT $ lambdaLit a b

-- | Builds the tree @x : xs@ as nested 'Cons' nodes ending in an empty list.
--
-- Note the fold direction: @foldr@ puts the head elements outermost, so
-- @listConsNode GInt [iLitT 1, iLitT 2]@ evaluates to @[1,2]@ in order.
listConsNode :: GType -> [Tree] -> Tree
listConsNode gType = foldr (\acc t -> Cons <| [acc, t]) (litT $ ListLit gType [])

-- * The measure cache

-- | Reads a tree's measure, computing and attaching it first if it is missing.
--
-- This is the safe entry point: callers never need to check whether the
-- cache is populated. The computed value is returned but /not/ written back
-- into the caller's tree (Haskell is immutable), so prefer
-- 'computeMeasure' once and then read many times.
getMeasure :: Tree -> Measure
getMeasure t = case _measure t of
  Nothing -> getMeasure $ computeMeasure t
  Just m -> m

-- | Height of the subtree (longest path to a leaf, in edges).
getHeight :: Tree -> Int
getHeight = _height . getMeasure

-- | Number of nodes in the subtree (leaves included).
getNodeCount :: Tree -> Int
getNodeCount = _nodeCount . getMeasure

-- | Distance from this node down to the root of the tree it belongs to.
--
-- Only meaningful after 'computeMeasure' has run on the /whole/ tree, since
-- the value is fixed at annotation time.
getCurrentDepth :: Tree -> Int
getCurrentDepth = _currentDepth . getMeasure

-- | Annotates every node of the tree with its measure, bottom-up.
--
-- The single traversal computes all three numbers at once:
--
-- * @\_currentDepth@ - passed down from the parent (+1 per level);
-- * @\_height@ - 1 + the largest child height (0 for a leaf);
-- * @\_nodeCount@ - 1 + the sum of the children's node counts.
--
-- Call this after building or mutating a tree and before relying on any of
-- the getters above.
computeMeasure :: Tree -> Tree
computeMeasure = go 0
  where
    go currentDepth l@Leaf {} =
      l
        { _measure =
            Just
              ( MkMeasure
                  { _currentDepth = currentDepth,
                    _height = 0,
                    _nodeCount = 1
                  }
              )
        }
    go currentDepth n@Node {_args = trees} = n {_measure = Just measure, _args = newTrees}
      where
        newTrees = go (currentDepth + 1) <$> trees
        measure =
          MkMeasure
            { _currentDepth = currentDepth,
              _height = 1 + maximum (getHeight <$> newTrees),
              _nodeCount = 1 + sum (getNodeCount <$> newTrees)
            }

-- | Drops the cached measure everywhere, forcing a recompute later.
--
-- Used after a transformation changes the shape of a tree: a stale measure
-- would silently report wrong sizes, so it is safer to invalidate than to
-- patch.
resetMeasure :: Tree -> Tree
resetMeasure = go 0
  where
    go currentDepth l@Leaf {} =
      l
        { _measure = Nothing
        }
    go currentDepth n@Node {_args = trees} = n {_measure = Nothing, _args = newTrees}
      where
        newTrees = go (currentDepth + 1) <$> trees