-- |
-- Module      : Grammar.Eval
-- Description : The interpreter: turns a Tree + inputs into a value (or a crash).
--
-- Running a candidate program means evaluating its 'Tree' against a list of
-- argument 'Lit's. The result is @Maybe Lit@:
--
-- * @Just v@  - the program produced a value;
-- * @Nothing@ - the program failed at runtime (division by zero, @head@ of an
--   empty list, NaN, out-of-range index, ...).
--
-- The distinction matters for fitness: a program that crashes on a training
-- case must not be rewarded, and 'Nothing' lets the caller score it as a
-- failure instead of accidentally producing a plausible-looking value.
--
-- Design notes:
--
-- * Evaluation is total in the sense that every 'Operation' has a clause, and
--   a pattern-match failure is a bug (it means the type checker let an
--   ill-typed program through) rather than an expected outcome.
-- * @if@ evaluates /both/ branches (they are already evaluated by the
--   argument-sequence walk before @eval@ sees them), so a branch that would
--   crash can take down the whole program even if it is not selected.
-- * Numeric guards (see 'Range', 'Sqrt', the NaN check in 'evalTree') exist
--   to keep the search from wandering into undefined behaviour: NaN results
--   are converted to @Nothing@ so they are never mistaken for good fitness.
module Grammar.Eval (evalTree, extractChar, extractFloat, extractInt, extractString, extractList) where

import Control.Monad
import Data.Char (isAlpha, isDigit)
import Data.List (foldl', intercalate)
import Data.Maybe (mapMaybe)
import Grammar.Core
import Grammar.Helpers (pairLit, stLit, tListLitOf)
import Grammar.Types
import Pretty (pretty)

-- | Evaluates a Tree with the given arguments.
--
-- The arguments are the values bound to @Arg 0@, @Arg 1@, ... of the
-- enclosing program. For a lambda body, 'evalLambda' passes a single
-- argument, so inside a lambda @Arg 0@ is the lambda parameter.
evalTree :: [Lit] -> Tree -> Maybe Lit
evalTree args (LeafArg i) =
  -- Out-of-range argument means the tree is malformed (a well-typed tree can
  -- never reference an argument that does not exist), so this is a hard error.
  if i < length args
    then Just $ args !! i
    else error $ "[EVAL] Could not get $" <> show i <> " from only " <> show (length args) <> " arguments: " <> pretty args
evalTree args (LeafLit v) = Just v
evalTree args Node {_operation = f, _args = opArgs} = do
  -- Evaluate children first (call-by-value), then apply the operator.
  evaluatedArgs <- sequence $ evalTree args <$> opArgs
  v <- eval f evaluatedArgs
  case v of
    FloatLit x -> do
      -- Reject NaN (e.g. 0/0 cannot happen because DivFloat guards 0, but
      -- other float ops can still produce it): a NaN would otherwise be
      -- indistinguishable from a real number when scoring fitness.
      guard (not $ isNaN x)
      return v
    _ -> return v

-- | Applies one operation to its already-evaluated arguments.
--
-- The first matching clause wins; clauses are ordered by type so that, for
-- instance, @AddInt@ never sees a 'FloatLit'. The catch-all at the end is
-- only reachable for ill-typed input, which 'Grammar.Types.typeCheck'
-- should have rejected earlier.
eval :: Operation -> [Lit] -> Maybe Lit
-- Int
eval AddInt [IntLit i1, IntLit i2] = Just $ IntLit (i1 + i2)
eval SubInt [IntLit i1, IntLit i2] = Just $ IntLit (i1 - i2)
eval MultInt [IntLit i1, IntLit i2] = Just $ IntLit (i1 * i2)
-- Division/modulo by zero returns Nothing (runtime failure) instead of
-- throwing, so the fitness function can count it as a wrong answer.
eval DivInt [IntLit _, IntLit 0] = Nothing
-- GHC's `div` overflows on minBound `div` (-1); special-case it.
eval DivInt [IntLit i1, IntLit (-1)] = Just $ IntLit $ negate i1
eval DivInt [IntLit i1, IntLit i2] = Just $ IntLit $ i1 `div` i2
eval ModInt [IntLit _, IntLit 0] = Nothing
eval ModInt [IntLit i1, IntLit i2] = Just $ IntLit $ i1 `mod` i2
eval MaxInt [IntLit i1, IntLit i2] = Just $ IntLit (max i1 i2)
eval MinInt [IntLit i1, IntLit i2] = Just $ IntLit (min i1 i2)
-- Bool
eval And [BoolLit b1, BoolLit b2] = Just $ BoolLit (b1 && b2)
eval Or [BoolLit b1, BoolLit b2] = Just $ BoolLit (b1 || b2)
eval Not [BoolLit b1] = Just $ BoolLit (not b1)
eval If [BoolLit cond, a, b] = Just $ if cond then a else b
-- Float
eval AddFloat [FloatLit f1, FloatLit f2] = Just $ FloatLit (f1 + f2)
eval SubFloat [FloatLit f1, FloatLit f2] = Just $ FloatLit (f1 - f2)
eval MultFloat [FloatLit f1, FloatLit f2] = Just $ FloatLit (f1 * f2)
eval DivFloat [FloatLit f1, FloatLit f2] = if f2 == 0 then Nothing else Just $ FloatLit $ f1 / f2
-- sqrt of a negative number is NaN, so take the absolute value to stay in
-- the domain of real numbers (this matches the benchmark's expectations).
eval Sqrt [FloatLit f] = Just $ FloatLit (sqrt $ abs f)
-- Char + Bool
eval EqChar [CharLit c1, CharLit c2] = Just $ BoolLit (c1 == c2)
eval IsLetter [CharLit c] = Just $ BoolLit (isAlpha c)
eval IsDigit [CharLit c] = Just $ BoolLit (isDigit c)
-- Float + Int
eval IntToFloat [IntLit i] = Just $ FloatLit (fromIntegral i)
eval Floor [FloatLit f] = Just $ IntLit (floor f)
-- Int + Bool
eval GtInt [IntLit i1, IntLit i2] = Just $ BoolLit (i1 > i2)
eval LtInt [IntLit i1, IntLit i2] = Just $ BoolLit (i1 < i2)
eval EqInt [IntLit i1, IntLit i2] = Just $ BoolLit (i1 == i2)
-- Lists
eval Len [ListLit _ l] = Just $ IntLit (length l)
-- `range start stop step` builds [start, start+step .. stop].
-- The guards keep it terminating and predictable:
--   * equal bounds yield the singleton [start];
--   * a zero step, or a step pointing away from the stop value, yields [];
--   * the take 5000 bound stops a small step over a huge interval from
--     allocating an unbounded list (a candidate program could otherwise
--     exhaust memory mid-run).
eval Range [IntLit start, IntLit stop, IntLit step]
  | start == stop = Just $ ListLit GInt [IntLit start]
  | step == 0 || signum step /= signum (stop - start) = Just $ ListLit GInt []
  | otherwise = Just $ ListLit GInt $ take 5000 $ IntLit <$> [start, (start + step) .. stop]
eval Cons [a, ListLit t l] = Just $ ListLit t (a : l)
eval Singleton [a] = Just $ ListLit (litType a) [a]
eval Head [ListLit gt l] = if null l then Nothing else Just $ head l
eval Reverse [ListLit t l] = Just $ ListLit t (reverse l)
-- map f xs: apply the lambda to every element. If any application fails,
-- the whole map fails (mapM short-circuits on Nothing).
eval Map [LambdaLit f, ListLit _ l] = ListLit (_outType $ _type f) <$> mapM (evalLambda f) l
-- concat: flatten a list of lists. foldl' is used (not ++) so that long
-- inputs do not build a huge thunk chain.
eval Concat [ListLit (GList t) l] = Just $ ListLit t $ foldl' append [] l
  where
    append :: [Lit] -> Lit -> [Lit]
    append acc (ListLit _ ls) = acc <> ls
    append _ v = error $ "[EVAL] Concat got ill-typed expression: " <> show v
-- filter p xs: keep the elements whose predicate returns BoolLit True.
-- A predicate returning a non-Bool is impossible for a type-checked tree,
-- hence the error branch marks it as an internal bug.
eval Filter [LambdaLit f, ListLit listType l] = ListLit listType <$> applyFilter l
  where
    applyFilter :: [Lit] -> Maybe [Lit]
    applyFilter [] = Just []
    applyFilter (t : ts) = do
      result <- evalLambda f t
      case result of
        BoolLit True -> (t :) <$> applyFilter ts
        BoolLit False -> applyFilter ts
        x -> error $ "[EVAL] Filter's predicate returned " <> show x <> ", which is not a Bool!"
eval Zip [ListLit t1 l1, ListLit t2 l2] = Just $ ListLit (GPair t1 t2) $ zipWith (curry pairLit) l1 l2
eval Take [IntLit n, ListLit t l] = Just $ ListLit t (take n l)
eval SumInts [ListLit GInt l] = Just $ IntLit $ sum $ extractInt <$> l
eval ProductInts [ListLit GInt l] = Just $ IntLit $ product $ extractInt <$> l
eval SumFloats [ListLit GFloat l] = Just $ FloatLit $ sum $ extractFloat <$> l
eval ProductFloats [ListLit GFloat l] = Just $ FloatLit $ product $ extractFloat <$> l
eval Unlines [ListLit (GList GChar) strings] = Just $ tListLitOf GChar CharLit $ intercalate "\n" $ extractString <$> strings -- the actual unlines puts a \n at the end
eval ShowInt [IntLit x] = Just $ stLit $ show x
-- Pair
eval ToPair [a, b] = Just $ PairLit a b
eval Fst [PairLit a b] = Just a
eval Snd [PairLit a b] = Just b
eval f vs = error $ "Cannot apply " <> show f <> " to " <> show vs

-- | Applies a lambda literal to a single argument by evaluating its body
-- with that argument bound to @Arg 0@.
evalLambda :: TypedTree -> Lit -> Maybe Lit
evalLambda f l = evalTree [l] (_tree f)

-- * Unsafe extractors
--
-- The functions below are partial on purpose: after type checking, a Lit of
-- the wrong shape indicates a bug elsewhere, and failing loudly is better
-- than silently returning 0. They are the \"trust me, the types are right\"
-- escape hatch used inside 'eval', where every clause already matched the
-- constructors it needs.

extractFloat :: Lit -> Float
extractFloat (FloatLit f) = f
extractFloat l = error $ "[EVAL] Cannot extract Float from " <> pretty l

extractInt :: Lit -> Int
extractInt (IntLit f) = f
extractInt l = error $ "[EVAL] Cannot extract Int from " <> pretty l

extractChar :: Lit -> Char
extractChar (CharLit f) = f
extractChar l = error $ "[EVAL] Cannot extract Char from " <> pretty l

-- | A Haskell 'String' is a @ListLit GChar@ in this language.
extractString :: Lit -> String
extractString (ListLit GChar ls) = extractChar <$> ls
extractString l = error $ "[EVAL] Cannot extract String from " <> pretty l

extractList :: Lit -> [Lit]
extractList (ListLit _ ls) = ls
extractList l = error $ "[EVAL] Cannot extract List from " <> pretty l
