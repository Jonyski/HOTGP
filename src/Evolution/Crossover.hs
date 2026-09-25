-- |
-- Module      : Evolution.Crossover
-- Description : Type-safe subtree swap between two parents.
--
-- Crossover is the main source of variation in GP: take two parents, pick a
-- subtree from each, and exchange them to get two children.
--
-- The hard part is doing that /without breaking types/. The algorithm here
-- is:
--
-- 1. pick a random node in parent 1 ('Point' in pre-order);
-- 2. compute the output type of the subtree at that point;
-- 3. collect every subtree of parent 2 whose output type matches AND whose
--   depth fits in the gap left by the swap ('getAllMatchingSubtrees');
-- 4. if none match, give up and return 'Nothing' (the caller keeps the
--   parents unchanged - no evaluation is wasted);
-- 5. otherwise pick one of them at random and perform the two-way swap.
--
-- The fit check is /two-way/: the incoming subtree must fit inside parent 1
-- given where it will sit, and vice versa. Both directions are needed
-- because each parent's remaining depth budget is different.
module Evolution.Crossover where

import Data.Foldable (Foldable (foldl'))
import Evolution.Config (Config (_maxTreeDepth, _programType))
import Evolution.Core (Point, St)
import Evolution.Helpers (atPoint, randomR, sample)
import Grammar
  ( FunctionType (_argTypes),
    GType,
    ProgramArgTypes,
    Tree (..),
    getCurrentDepth,
    getHeight,
    getNodeCount,
    inferOutputType,
  )

-- | Gets all subtrees from `tree` that can be crossed with `branch`
-- TODO: Write tests
--
-- Returns the candidates paired with their 'Point' so the caller can
-- perform the swap without a second search.
getAllMatchingSubtrees :: Config a -> Tree -> Tree -> [(Point, Tree)]
getAllMatchingSubtrees cfg branch tree = snd $ go 1 tree
  where
    argTypes = _argTypes $ _programType cfg
    -- The type the donor subtree must have: whatever `branch` produces.
    desiredOutType = inferOutputType argTypes branch
    satisfies candidateBranch =
      inferOutputType argTypes candidateBranch == desiredOutType -- types match
        && candidateBranch `fitsIn` branch
        && branch `fitsIn` candidateBranch

    -- Would `src` still respect the depth limit when placed where `dest`
    -- currently sits? Uses src's height plus dest's remaining depth.
    fitsIn :: Tree -> Tree -> Bool
    fitsIn src dest = getCurrentDepth dest + getHeight src <= _maxTreeDepth cfg

    -- Pre-order walk: number every node starting at 1, keeping only the
    -- ones that satisfy the constraints above.
    go n t@Node {_args = trs} = (nChildren, this ++ children)
      where
        this = [(n, t) | satisfies t]
        (nChildren, children) = foldl' f (n + 1, []) trs
        f (p, ls) tr = (ls ++) <$> go p tr
    go n t@Leaf {} = (n + 1, this)
      where
        this = [(n, t) | satisfies t]

-- TODO: Write tests
-- | Returns the subtree rooted at the given pre-order position.
--
-- Same navigation idea as 'Evolution.Helpers.atPoint': compare the target
-- index against each child's node count to decide whether to skip the child
-- or descend into it. Positions @<= 1@ denote the current node.
getBranchAt :: Point -> Tree -> Tree
getBranchAt p t@Node {_args = ch}
  | p > 1 =
    getChildren (p - 1) ch
  where
    getChildren p (t : ts) =
      let n = getNodeCount t
       in if n < p
            then getChildren (p - n) ts
            else getBranchAt p t
    getChildren _ _ = error "This should never happen"
getBranchAt _ t = t

-- | Performs the crossover of two trees.
--
-- Returns @Nothing@ when no compatible subtree exists in the second parent
-- (see the module header); otherwise @Just (child1, child2)@ where each
-- child keeps one parent's skeleton and the other's transplanted branch.
crossOver :: Config a -> Tree -> Tree -> St (Maybe (Tree, Tree))
crossOver cfg t1 t2 = do
  -- Step 1+2: choose the branch to donate from t1.
  p1 <- randomR (1, getNodeCount t1)
  let b1 = getBranchAt p1 t1
      -- Step 3: everything in t2 that could legally receive b1.
      matchingT2 = getAllMatchingSubtrees cfg b1 t2

  case matchingT2 of
    [] -> return Nothing -- step 4: no compatible partner, keep the parents
    m -> do
      -- Step 5: pick a partner uniformly and swap both ways.
      (p2, b2) <- sample m
      c1 <- atPoint p1 (const $ return b2) t1
      c2 <- atPoint p2 (const $ return b1) t2
      return $ Just (c1, c2)
