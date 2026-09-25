-- |
-- Module      : Evolution.Helpers
-- Description : Randomness in the St monad, and \"apply at a tree position\".
--
-- Two small utilities that every genetic operator needs:
--
-- 1. /Random draws/ ('random', 'randomR', 'sample') - thin wrappers over
--    @System.Random@ that pull values from the generator held in the 'St'
--    state. Nothing in the project uses IO randomness, which is why a run
--    is fully reproducible from its seed.
--
-- 2. /Position-addressed mutation/ ('atPoint', 'atRandomPoint') - the
--    mechanism for \"change something at this spot in the tree\". A 'Point'
--    is the node's index in a pre-order traversal; 'atPoint' walks the tree
--    once, keeping track of how many nodes each subtree owns, to find it.
module Evolution.Helpers where

import qualified Control.Monad.State.Strict as S
import qualified Data.Vector as V
import Evolution.Core (Mutation, Point, St)
import Grammar (Tree (..), getNodeCount)
import qualified System.Random as R

-- | Selects a random value from a uniform type.
random :: (R.Uniform a) => St a
random = S.state R.uniform

-- | Gets an infinite list of random values, splitting the generator off so
-- the caller's state is advanced only once.
randoms :: (R.Random a) => St [a]
randoms = S.state (\g -> let (g1, g2) = R.split g in (R.randoms g1, g2))

-- | Selects a random value within a range (inclusive on both ends).
randomR :: (R.UniformRange a) => (a, a) -> St a
randomR = S.state . R.uniformR

-- | Uniformly samples one element of a list.
--
-- Errors on the empty list: sampling from nothing is always a bug at the
-- call site (e.g. asking for a crossover partner in an empty pool).
sample :: [a] -> St a
sample [] = error "Sampling empty list!"
sample xs = do
  let l = length xs - 1
  idx <- randomR (0, l)
  return $ xs !! idx

-- | Turns a node-local mutation into a whole-tree mutation by first picking
-- a random position to apply it to.
--
-- The point is drawn uniformly from @1 .. nodeCount@, so every node -
-- including the root - is equally likely to be the mutation point. This is
-- the standard Koza-style \"point mutation\".
atRandomPoint :: Mutation -> Mutation
atRandomPoint f tree = do
  let n = getNodeCount tree
  point <- randomR (1, n)
  atPoint point f tree

-- | Applies a mutation to the subtree at a specific pre-order position.
--
-- The position numbering is 1-based and follows a depth-first, left-to-right
-- walk, e.g. for
--
-- @
-- 1 [2 [3,4], 5, [6,7]]
-- @
--
-- node @3@ is the first child of the first child. The walk uses node counts
-- to decide which child contains the target: if the target index is larger
-- than a child's whole subtree size, skip the child and continue with the
-- index offset by that size; otherwise descend into it.
--
-- Returns the mutation's result in 'St', because the mutation itself may
-- draw random numbers.
atPoint ::
  -- | Integer representing the pre-ordered 1-indexed position (i.e., 1 [2 [3,4], 5, [6,7]]).
  Point ->
  Mutation ->
  Mutation
atPoint n f t@Leaf {} = f t
atPoint point f t@(Node measure v ch)
  | point <= 1 = f t -- found it
  | otherwise = Node measure v <$> changeChildren (point - 1) f ch -- it surely is in the children
  where
    changeChildren :: Point -> Mutation -> [Tree] -> St [Tree]
    changeChildren p f [] = return []
    changeChildren p f (t : ts) =
      if n < p
        then
          (t :)
            <$> changeChildren (p - n) f ts -- not in this child, try the next one
        else (: ts) <$> atPoint p f t -- it is in this child, lets search for it
      where
        n = getNodeCount t

-- | Unwraps a pair into a two-element list (used to feed crossover results
-- back into @mapM@-style code).
tupleToList :: (a, a) -> [a]
tupleToList (x, y) = [x, y]

-- | Lifts a pure state computation into a state transformer with an
-- arbitrary base monad (usually IO), keeping the same generator state.
--
-- This is the bridge between the pure 'St' world of the genetic operators
-- and the @StateT StdGen IO@ world of the run loop, which also needs to
-- write logs and checkpoints.
hoistState :: Monad m => S.State s a -> S.StateT s m a
hoistState = S.state . S.runState