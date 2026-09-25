-- |
-- Module      : Grammar.Simplify
-- Description : Algebraic rewrite rules that shrink programs without changing
--               their meaning.
--
-- Why simplify at all?
--
-- Genetic programming happily produces correct-but-bloated trees such as
-- @(x + 0) * 1@ or @if True then a else b@. Two things go wrong:
--
-- * /bloat/ wastes the tree-size budget imposed by the depth limits, which
--   the search could have spent on useful structure;
-- * /equivalent-looking variants/ are treated as distinct individuals, so
--   the population fills up with clones in disguise.
--
-- Simplification fixes both by applying semantics-preserving rewrites:
-- constant folding, identities (@x + 0 = x@), annihilators (@x * 0 = 0@),
-- simplification of conditionals, and a few list-specific laws.
--
-- How it works
-- ------------
-- The entry point is 'simplifyTree'. It first simplifies the children, then
-- tries to collapse the node itself in three ways, in order:
--
-- 1. /Constant folding/ - if every child is now a literal, evaluate the node
--    outright with 'Grammar.Eval.evalTree' and replace it with the result.
--    (A failed evaluation leaves the node as is: it may still be useful in
--    other contexts.)
-- 2. /Commutativity normalisation/ - for commutative operators, try every
--    permutation of the children and keep the smallest result. This gives a
--    canonical argument order, which helps deduplication.
-- 3. /Rule matching/ - 'applyRules' fires the pattern-based rules below.
--
-- Rules are written as one guard per equation in 'go', so adding a new
-- simplification means adding one line there.
module Grammar.Simplify where

import Data.Function (on)
import Data.List (minimumBy, permutations)
import Grammar

-- | Simplifies a tree bottom-up (children first, then the node itself).
--
-- Lambdas are entered as well, so a candidate @map (\\y -> y + 0) xs@ ends
-- up as @map (\\y -> y) xs@. Leaves need no work.
simplifyTree :: Tree -> Tree
simplifyTree Node {_operation = op, _args = trs}
  -- If every child folded to a literal, the whole node is a constant:
  -- evaluate it. evalTree returns Nothing when the evaluation is invalid
  -- (e.g. 1/0), in which case we keep the node instead of crashing.
  | all isLit simplifiedChildren = maybe newTree LeafLit (evalTree [] newTree)
  | otherwise = newTree
  where
    simplifiedChildren = simplifyTree <$> trs
    newTree
      -- Commutative operators: pick the permutation that yields the smallest
      -- tree, which makes the canonical form stable regardless of how the
      -- tree was grown.
      | op `elem` commutativeOps = minimumBy (compare `on` getNodeCount) $ applyRules . (op <|) <$> permutations simplifiedChildren
      | otherwise = applyRules $ op <| simplifiedChildren
      where
        commutativeOps = [AddInt, MultInt, AddFloat, MultFloat, And, Or, EqInt, EqChar]
-- Recurse into lambda bodies (a lambda is a literal, but a special one).
simplifyTree (LeafLit (LambdaLit (MkTypedTree tree ft))) = lambdaLitT (simplifyTree tree) ft
simplifyTree x = x

-- | Reassociates a nested use of the /same/ associative operator so that the
-- constant operands end up next to each other, where 'applyRules' can fold
-- them.
--
-- Matches both @a op (b op x)@ and @(a op x) op b@ and rebuilds them as
-- @(a op b) op x@. Example: @1 + (x + 2)@ becomes @(1 + 2) + x@, and the
-- @AddInt@ identity rules then reduce it to @x + 3@.
--
-- Returns 'Nothing' when the shape does not match, so the caller keeps the
-- original tree.
applyAssociativeRules :: Tree -> Maybe Tree
applyAssociativeRules
  Node
    { _operation = op1,
      _args = [LeafLit a, Node {_operation = op2, _args = [LeafLit b, x]}]
    }
    | op1 == op2 = Just $ op1 <| [op1 <| [LeafLit a, LeafLit b], x]
applyAssociativeRules
  Node
    { _operation = op1,
      _args = [LeafLit a, Node _ op2 [x, LeafLit b]]
    }
    | op1 == op2 = Just $ op1 <| [op1 <| [LeafLit a, LeafLit b], x]
applyAssociativeRules _ = Nothing

-- | The rule table: pattern-matches a node against every known simplification
-- and returns the rewritten node, or 'Nothing' if none apply.
--
-- The rules fall into families:
--
-- * /associativity/ - reassociate so constants can be merged (above);
-- * /conditionals/ - @if True then a else b = a@, @if c then a else a = a@,
--   @if (not c) then a else b = if c then b else a@;
-- * /reflexivity/ - @x == x = True@, @x < x = False@, @x - x = 0@, ...;
-- * /identities and annihilators/ - @x + 0 = x@, @x * 0 = 0@, @x / 1 = x@;
-- * /cancellation/ - @(a * b) / a = b@ (integer division, exact case);
-- * /pair projection/ - @fst (a, b) = a@;
-- * /boolean algebra/ - short-circuit @&&@/@||@ with literal operands;
-- * /list laws/ - @length [..]@, @reverse (reverse x) = x@,
--   @take (length x) x = x@, @head (singleton x) = x@, ...;
-- * /equality against an if/@ - @(if c then a else b) == r@ collapses to a
--   formula over @c@ (see 'applyEqualIfRule').
--
-- Every rewrite is semantics-preserving, which is what lets the pruner run
-- this on already-validated solutions.
applyRules :: Tree -> Tree
applyRules Node {_operation = op, _args = trs} = maybe (op <| trs) simplifyTree (go op trs)
  where
    go :: Operation -> [Tree] -> Maybe Tree
    go op trs
      | op `elem` associativeOps,
        Just simplified <- applyAssociativeRules $ op <| trs =
        Just simplified
      where
        associativeOps = [AddInt, AddFloat, MultInt, MultFloat, And, Or, MaxInt, MinInt]
    -- Conditionals with a constant condition, or identical branches.
    go If [LeafLit (BoolLit True), used, _] = Just used
    go If [LeafLit (BoolLit False), _, used] = Just used
    go If [_, a, b] | a == b = Just a
    -- Reflexive comparisons / operations.
    go EqInt [a, b] | a == b = Just $ bLitT True
    go LtInt [a, b] | a == b = Just $ bLitT False
    go GtInt [a, b] | a == b = Just $ bLitT False
    go MaxInt [a, b] | a == b = Just a
    go MinInt [a, b] | a == b = Just a
    go And [a, b] | a == b = Just a
    go Or [a, b] | a == b = Just a
    go EqChar [a, b] | a == b = Just $ bLitT True
    go SubInt [a, b] | a == b = Just $ iLitT 0
    go SubFloat [a, b] | a == b = Just $ fLitT 0
    go DivInt [a, b] | a == b = Just $ iLitT 1
    go ModInt [a, b] | a == b = Just $ iLitT 0
    go DivFloat [a, b] | a == b = Just $ fLitT 1
    -- Cancellation of a matching factor: (a*b)/a = b, (a*b) `mod` a = 0.
    -- Only valid because Int division here is exact for that shape.
    go DivInt [Node {_operation = MultInt, _args = [a, b]}, c]
      | a == c = Just b
      | b == c = Just a
    go ModInt [Node {_operation = MultInt, _args = [a, b]}, c] | a == c || b == c = Just $ iLitT 0
    go DivFloat [Node {_operation = MultFloat, _args = [a, b]}, c]
      | a == c = Just b
      | b == c = Just a
    -- Pair construction immediately followed by projection.
    go Fst [Node {_operation = ToPair, _args = [a, b]}] = Just a
    go Snd [Node {_operation = ToPair, _args = [a, b]}] = Just b
    -- Boolean short-circuits.
    go Or [LeafLit (BoolLit True), _] = Just $ bLitT True
    go Or [LeafLit (BoolLit False), x] = Just x
    go And [LeafLit (BoolLit False), _] = Just $ bLitT False
    go And [LeafLit (BoolLit True), x] = Just x
    -- Additive / multiplicative identities and annihilators.
    go AddInt [LeafLit (IntLit 0), x] = Just x
    go AddFloat [LeafLit (FloatLit 0), x] = Just x
    go AddFloat [x, LeafLit (FloatLit 0)] = Just x
    go SubInt [x, LeafLit (IntLit 0)] = Just x
    go SubFloat [x, LeafLit (FloatLit 0)] = Just x
    go MultInt [LeafLit (IntLit 1), x] = Just x
    go MultFloat [LeafLit (FloatLit 1), x] = Just x
    go MultInt [LeafLit (IntLit 0), x] = Just $ iLitT 0
    go MultFloat [LeafLit (FloatLit 0), x] = Just $ fLitT 0
    go DivInt [x, LeafLit (IntLit 1)] = Just x
    go ModInt [x, LeafLit (IntLit 1)] = Just $ iLitT 0
    go DivFloat [x, LeafLit (FloatLit 1)] = Just x
    -- List laws.
    go Len [LeafLit (ListLit _ ls)] = Just $ iLitT (length ls) -- fold a literal list
    go Len [Node {_operation = Singleton}] = Just $ iLitT 1
    go Len [Node {_operation = Cons, _args = [x, xs]}] = Just $ AddInt <| [iLitT 1, Len <| [xs]]
    go Len [Node {_operation = Reverse, _args = x}] = Just $ Len <| x
    go Head [Node {_operation = Singleton, _args = [x]}] = Just x
    go Reverse [Node {_operation = Singleton, _args = x}] = Just $ Singleton <| x
    go SumInts [Node {_operation = Singleton, _args = [x]}] = Just x
    go ProductInts [Node {_operation = Singleton, _args = [x]}] = Just x
    go Reverse [Node {_operation = Reverse, _args = [x]}] = Just x -- involution
    go Take [Node {_operation = Len, _args = [x]}, y] | x == y = Just x
    go Range [start, stop, _] | start == stop = Just $ Singleton <| [start]
    -- Negating the condition swaps the branches instead of wrapping in `not`.
    go If [Node {_operation = Not, _args = [cond]}, a, b] = Just $ If <| [cond, b, a]
    -- `(if c then a else b) == r` where a, b, r are literals: decide
    -- without evaluating the branch that is not taken.
    go EqInt [Node {_operation = If, _args = [cond, LeafLit a, LeafLit b]}, LeafLit ref] = Just $ applyEqualIfRule cond a b ref
    go EqInt [LeafLit ref, Node {_operation = If, _args = [cond, LeafLit a, LeafLit b]}] = Just $ applyEqualIfRule cond a b ref
    go op trs = Nothing -- no rule applies: keep the node as it is
applyRules x = x

-- | Helper for the @(if c then a else b) == r@ rule.
--
-- Three cases:
--
-- * @a == r@ - equality holds exactly when the condition holds, so the
--   expression reduces to @c@;
-- * @b == r@ - equality holds when the condition does /not/ hold, hence
--   @not c@;
-- * neither branch equals the reference - the comparison can never succeed.
applyEqualIfRule :: Tree -> Lit -> Lit -> Lit -> Tree
applyEqualIfRule cond a b reference
  | a == reference = cond
  | b == reference = Not <| [cond]
  | otherwise = bLitT False

-- | Is this node a literal leaf? (Used to decide whether constant folding
-- can fire.)
isLit :: Tree -> Bool
isLit Leaf {_terminal = (Literal lit)} = True
isLit _ = False
