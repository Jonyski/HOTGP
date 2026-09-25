-- |
-- Module      : Grammar.Pretty
-- Description : Renders grammar values as (roughly) Haskell-like source text.
--
-- Printing serves two audiences:
--
-- * /humans/ reading logs, the \"perfect solution found\" message and the
--   pruned output files;
-- * /tests/, which compare pretty-printed programs against expected strings.
--
-- The output is intentionally close to Haskell syntax (@if c then a else b@,
-- @x0 + 1@, @map (\\y -> y) xs@) so a reader can recognise a solution at a
-- glance. It is /not/ a parser target - nothing in the project reads these
-- strings back.
--
-- Formatting strategy for nodes:
--
-- 1. if it is @if@, use the special ternary layout;
-- 2. if the operation has an infix symbol ('binaryOperatorMap'), print it
--    infix with parentheses only where a sub-node needs them;
-- 3. if it has a nicer function name ('customNameMap', e.g. @Len@ -> @length@),
--    print it as a call;
-- 4. otherwise fall back to the constructor name with its first letter
--    lowercased (@Singleton xs@ becomes @singleton xs@).
module Grammar.Pretty where

import Data.Char (toLower)
import Data.List (intercalate, stripPrefix)
import qualified Data.Map as M
import Grammar.Core
import Pretty (Pretty (..))

instance Pretty Lit where
  pretty (IntLit i) = show i
  pretty (FloatLit f) = show f
  pretty (BoolLit b) = show b
  pretty (CharLit s) = show s
  -- A list of chars prints as a Haskell string literal ("abc") rather than
  -- ['a','b','c'], because that is what the benchmarks deal in.
  pretty (ListLit GChar lits) = show $ extractChar <$> lits
    where
      extractChar (CharLit c) = c
      extractChar _ = error "Pretty: Cannot pretty list of mixed typed"
  pretty (ListLit _ lits) = "[" <> commas (pretty <$> lits) <> "]"
  -- Lambdas print their bound variable as `y`; the body was written using
  -- `x0` for the parameter, so rename it during printing to avoid the
  -- confusing `\\x0 -> x0`.
  pretty (LambdaLit tr) = parens $ "\\y -> " <> replace "x0" "y" (pretty tr)
  pretty (PairLit a b) = parens $ commas $ pretty <$> [a, b]

instance Pretty TypedTree where
  pretty = pretty . _tree

instance Pretty Terminal where
  pretty (Arg a) = "x" <> show a -- argument 0 prints as `x0`
  pretty (Literal val) = pretty val

-- | Substring replacement (used to rename lambda parameters for printing).
--
-- Replaces every non-overlapping occurrence of @from@ in @xs@ by @to@,
-- scanning left to right. Errors on an empty @from@ to avoid an infinite
-- loop at the call site.
replace :: (Eq a) => [a] -> [a] -> [a] -> [a]
replace [] _ _ = error "replace, first argument cannot be empty"
replace from to xs | Just xs <- stripPrefix from xs = to ++ replace from to xs
replace from to (x : xs) = x : replace from to xs
replace from to [] = []

-- | Join with commas (no spaces; used inside @[...]@ and @(a,b)@).
commas :: [String] -> String
commas = intercalate ","

-- | Prints a node's arguments as a space-separated run, parenthesising the
-- ones that are themselves nodes so precedence survives: @(x0 + 1) * 2@.
args :: [Tree] -> String
args = (' ' :) . unwords . map parensIfNeeded

-- | Parenthesise a node, leave a leaf bare.
parensIfNeeded :: Tree -> String
parensIfNeeded t@Node {} = parens $ pretty t
parensIfNeeded t = pretty t

parens :: String -> String
parens s = "(" <> s <> ")"

-- | Lowercase the first character (used for the fallback node layout).
lowerFirst :: String -> String
lowerFirst (x : xs) = toLower x : xs
lowerFirst x = x

-- | Infix symbols for the operations that deserve them.
binaryOperatorMap :: M.Map Operation String
binaryOperatorMap =
  M.fromList
    [ (AddInt, "+"),
      (AddFloat, "+"),
      (SubInt, "-"),
      (SubFloat, "-"),
      (MultInt, "*"),
      (MultFloat, "*"),
      (DivFloat, "/"),
      (GtInt, ">"),
      (LtInt, "<"),
      (EqInt, "=="),
      (EqChar, "=="),
      (And, "&&"),
      (Or, "||"),
      (Cons, ":")
    ]

-- | Nicer function names for operations whose constructor names read poorly
-- (@Len@ -> @length@, @IntToFloat@ -> @fromIntegral@, ...).
customNameMap :: M.Map Operation String
customNameMap =
  M.fromList
    [ (MaxInt, "max"),
      (MinInt, "min"),
      (DivInt, "div"),
      (ModInt, "mod"),
      (Len, "length"),
      (SumFloats, "sum"),
      (SumInts, "sum"),
      (ProductFloats, "product"),
      (ProductInts, "product"),
      (IntToFloat, "fromIntegral")
    ]

-- | Renders @t1 op t2@, guarding against an arity mismatch (which would mean
-- a node was built with the wrong number of children).
prettyBinaryOperator :: String -> [Tree] -> String
prettyBinaryOperator op [t1, t2] = parensIfNeeded t1 <> " " <> op <> " " <> parensIfNeeded t2
prettyBinaryOperator op ts =
  error $
    "[PRTY] "
      <> show op
      <> " expects 2 arguments, but got "
      <> show (length ts)
      <> ": "
      <> pretty ts

instance Pretty Tree where
  pretty Leaf {_terminal = v} = pretty v
  pretty Node {_operation = If, _args = [a, b, c]} = unwords ["if", parensIfNeeded a, "then", parensIfNeeded b, "else", parensIfNeeded c]
  pretty Node {_operation = f, _args = ts}
    | Just op <- M.lookup f binaryOperatorMap =
      prettyBinaryOperator op ts
  pretty Node {_operation = f, _args = ts}
    | Just op <- M.lookup f customNameMap =
      op <> args ts
  pretty Node {_operation = ToPair, _args = ts} = parens . commas $ pretty <$> ts
  -- Fallback: turn the constructor name into a function call.
  pretty Node {_operation = x, _args = ts} = lowerFirst (show x) <> args ts

-- | Lists print as @[a, b, c]@. Marked OVERLAPPABLE so the specific
-- @Lit@/@GType@ instances above win when they apply.
instance {-# OVERLAPPABLE #-} Pretty a => Pretty [a] where
  pretty xs = "[" <> intercalate ", " (map pretty xs) <> "]"

instance Pretty GType where
  pretty GInt = "Int"
  pretty GFloat = "Float"
  pretty GBool = "Bool"
  pretty GChar = "Char"
  pretty (GPair a b) = parens . commas $ pretty <$> [a, b]
  -- GPoly 0 -> "a", GPoly 1 -> "b", ... (the usual Haskell variable names).
  pretty (GPoly n) = [toEnum (fromEnum 'a' + n)]
  pretty (GList gt) = "[" <> pretty gt <> "]"
  pretty (GLambda ft) = "(" <> pretty ft <> ")"

instance Pretty FunctionType where
  pretty ot = intercalate " -> " (pretty <$> _argTypes ot <> [_outType ot])
