-- |
-- Module      : Benchmark.Metrics
-- Description : The scoring functions a benchmark can use.
--
-- Every metric has the shape @Lit -> Lit -> Sum x@: it takes the expected
-- value and the produced value and returns how /wrong/ the answer is,
-- wrapped in a 'Sum' so that scoring a whole test set is just a 'mconcat'
-- over the per-case numbers (see the @fitness@ function built in
-- "Benchmark.BenchmarkToConfig").
--
-- Lower is better, and 0 means \"correct on every case\" - the convention
-- the whole ranking machinery relies on.
--
-- The metrics differ in how they grade closeness:
--
-- * 'rightWrong'  - exact match only (used for booleans, exact integers);
-- * 'intError'    - absolute difference (an answer 5 too high costs 5);
-- * 'floatError'  - absolute difference for continuous outputs;
-- * 'levenshteinDistance' / 'prettyLevenshteinDistance' - edit distance,
--   for problems whose output is a string/list (partial matches count).
module Benchmark.Metrics where

import Data.Array (array, listArray, (!))
import Data.Semigroup
import Grammar
import Pretty

-- | Absolute error between two floats. Crashes if either value is not a
-- 'FloatLit', which means the benchmark's declared output type is wrong.
floatError :: Lit -> Lit -> Sum Float
floatError (FloatLit x) (FloatLit y) = Sum $ abs (x - y)
floatError a b = error $ "Can't apply floatError to" <> pretty a <> " and " <> pretty b

-- | Absolute error between two integers, widened to 'Integer' so that
-- large differences cannot overflow.
intError :: Lit -> Lit -> Sum Integer
intError (IntLit x) (IntLit y) = Sum $ abs $ toInteger x - toInteger y
intError a b = error $ "Can't apply intError to" <> pretty a <> " and " <> pretty b

-- | 0 for a correct boolean, 1 otherwise (no partial credit).
boolError :: Lit -> Lit -> Sum Integer
boolError (BoolLit x) (BoolLit y) = Sum $ if x == y then 0 else 1
boolError a b = error $ "Can't apply boolError to" <> pretty a <> " and " <> pretty b

-- | Levenshtein distance between the elements of two list literals: the
-- minimum number of single-element edits (insert/delete/replace) needed to
-- turn one into the other. Gives partial credit for near-miss strings.
levenshteinDistance :: Lit -> Lit -> Sum Integer
levenshteinDistance a b = Sum $ toInteger $ getLevenshteinDistance (extractList a) (extractList b)

-- | Same, but computed on the pretty-printed forms - convenient when the
-- two sides are of slightly different (but printable) shapes.
prettyLevenshteinDistance :: Lit -> Lit -> Sum Integer
prettyLevenshteinDistance a b = Sum $ toInteger $ getLevenshteinDistance (pretty a) (pretty b)

--  https://www.reddit.com/r/programming/comments/w4gs6/comment/c5a6jjz/?utm_source=share&utm_medium=web2x&context=3
-- | Levenshtein distance between two sequences, in O(n*m) time and space.
--
-- The classic dynamic program: fill a table where cell @(u,v)@ holds the
-- edit distance between the first @u@ elements of @xs@ and the first @v@ of
-- @ys@. Each cell depends only on its three neighbours (delete, insert,
-- substitute), plus the diagonal freebie when the elements already match.
--
-- The table is built lazily by 'array', so entries are computed on demand
-- in the order the recurrence reaches them - no explicit loops needed.
getLevenshteinDistance :: (Eq a) => [a] -> [a] -> Int
getLevenshteinDistance xs ys = levMemo ! (n, m)
  where
    levMemo = array ((0, 0), (n, m)) [((i, j), lev i j) | i <- [0 .. n], j <- [0 .. m]]
    n = length xs
    m = length ys
    -- listArray is 1-indexed here to match the usual formulation of the
    -- recurrence (with row/column 0 as the empty-sequence base case).
    xa = listArray (1, n) xs
    ya = listArray (1, m) ys
    lev 0 v = v -- aligning with the empty sequence costs v insertions
    lev u 0 = u -- ... or u deletions
    lev u v
      | xa ! u == ya ! v = levMemo ! (u -1, v -1) -- match: free
      | otherwise =
        1
          + minimum
            [ levMemo ! (u, v -1), -- insert
              levMemo ! (u -1, v), -- delete
              levMemo ! (u -1, v -1) -- substitute
            ]

-- | 0 if the two values are exactly equal, 1 otherwise - the strictest
-- metric, used where any deviation is a wrong answer.
rightWrong :: Lit -> Lit -> Sum Integer
rightWrong a b = Sum $ if a == b then 0 else 1