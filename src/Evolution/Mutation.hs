-- |
-- Module      : Evolution.Mutation
-- Description : Subtree replacement mutation (Koza's classic operator).
--
-- Mutation works as follows:
-- 1. randomly select a node within the parent tree as the mutation point,
-- 2. generate a new tree of maximum depth MAX-MUTATION-TREE-DEPTH,
-- 3. replace the subtree rooted at the selected node with the generated tree, and
-- 4. if the maximum depth of the child is less than or equal to MAX-TREE-DEPTH, then use it.
--     If the maximum depth is greater than MAX-TREE-DEPTH, then either use the parent (Koza) or start again from scratch (STGP)
--
-- The genetic operators, like the initial tree generator, must respect the type constraints on the parse trees.
-- Mutation uses the same algorithm employed by the initial tree generator to create a new subtree that returns the same type
-- as the deleted subtree and that has internal consistency between argument types and return types.
-- If it is impossible to generate such a tree, then the mutation operator returns either the parent or nothing.
--
-- Why these constraints matter: a naive \"replace a random subtree with a
-- random tree\" would produce ill-typed programs most of the time, wasting
-- evaluations. Generating the replacement /for/ the required output type
-- (and clamping the remaining depth budget) keeps every child valid and
-- inside the size limits, so the evaluation budget is spent on programs
-- that can actually run.
module Evolution.Mutation (mutate) where

import Evolution.Config
  ( Config (_maxMutationTreeDepth, _maxTreeDepth, _programType),
  )
import Evolution.Core (Mutation)
import Evolution.Generate (grow)
import Evolution.Helpers (atRandomPoint)
import Grammar
import Pretty
import qualified System.Random as R

-- | Builds a replacement subtree for the node currently being mutated.
--
-- Two constraints are enforced:
--
-- * /type/ - the new subtree must produce the same output type as the one
--   it replaces ('inferOutputType' works this out from the tree's context),
--   so the parent stays well-typed;
-- * /depth/ - the budget is the smaller of the configured mutation depth and
--   whatever room is left before hitting the global _maxTreeDepth. Using
--   @\_maxTreeDepth - getCurrentDepth tree@ means a mutation near the
--   bottom of a deep tree is forced to be shallow, which is what keeps the
--   tree from growing without bound.
replaceSubtree :: Ord a => Config a -> Mutation
replaceSubtree config tree =
  grow
    config
    (min (_maxMutationTreeDepth config) (_maxTreeDepth config - getCurrentDepth tree))
    (inferOutputType argTypes tree)
  where
    argTypes = _argTypes $ _programType config

-- | Randomly selects a node and replaces it with a new subtree that returns the same type as the deleted one.
mutate :: Ord a => Config a -> Mutation
mutate cfg = atRandomPoint (replaceSubtree cfg)
