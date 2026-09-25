{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE PatternSynonyms #-}

-- |
-- Module      : Grammar.Core
-- Description : The core data types of the GP language (types, literals, AST).
--
-- This module defines the *language* that genetic programming searches over.
-- Everything else in the project manipulates the values defined here, so it is
-- the best place to start reading.
--
-- The three things you need to understand first:
--
-- 1. __'GType'__ - the type system of our little language. It mirrors Haskell
--    types (@Int@, @Float@, @Bool@, @Char@, pairs, lists, functions) plus
--    'GPoly', a type /variable/ used for polymorphic operations such as
--    @map@ or @if@ (the \"higher-order\" and \"typed\" parts of HOTGP).
--
-- 2. __'Tree'__ - a program, represented as an expression tree. Leaves are
--    either a function argument ('Arg') or a constant ('Literal'); internal
--    nodes are operations ('Operation') applied to their subtrees.
--
-- 3. __'Operation'__ - the fixed set of building blocks (primitives) the
--    search may combine. A program can only be built from these, so this
--    enum *is* the grammar's vocabulary.
--
-- A concrete example: the Haskell expression @length (filter even xs)@
-- would be encoded as
--
-- @
-- Node Len [Node Filter [Leaf (Literal (LambdaLit ...)), Leaf (Arg 0)]]
-- @
--
-- Programs are kept untyped at the value level ('Tree' carries no type
-- information) and are checked on demand by 'Grammar.Types.typeCheck'.
-- This keeps trees cheap to copy during evolution; type information is only
-- materialised as 'TypedTree' when a lambda literal needs to remember the
-- type of the function it holds.
module Grammar.Core where

import GHC.Generics (Generic)

-- * Data Types

-- | Types supported by the grammar.
--
-- 'GPoly' is a type /variable/ (also called a type parameter): @GPoly 0@ is
-- the first unknown type, written @a@ when pretty-printed, @GPoly 1@ is @b@,
-- and so on. It lets a single operation such as
--
-- @
-- Map :: (a -> b) -> [a] -> [b]
-- @
--
-- be reused at every element type. The unifier in "Grammar.Types"
-- ('Grammar.Types.unifyTypes') replaces these variables with concrete types
-- as the tree is checked.
data GType
  = -- | 32-bit integers.
    GInt
  | -- | Single-precision floats (deliberately 'Float', not 'Double': the
    -- benchmarks compare against 'Float' expectations from the datasets).
    GFloat
  | -- | Booleans.
    GBool
  | -- | Characters; a string is represented as @GList GChar@.
    GChar
  | -- | A homogeneous pair, e.g. @GPair GInt GBool@ is @(Int, Bool)@.
    GPair !GType !GType
  | -- | A type variable. @GPoly 0@ would be "t0" (pretty-printed as @a@).
    -- The 'Int' is the de Bruijn-like index of the variable.
    GPoly !Int
  | -- | List of @a@, written @[a]@.
    GList !GType
  | -- | Function type @a -> b@. Present because lambdas are first-class
    -- values in this language: @map@ and @filter@ take one as an argument.
    GLambda FunctionType
  deriving (Show, Eq, Ord, Read, Generic)

-- | List of types of the arguments expected by the function.
--
-- The order matters: @Arg 0@ in a tree refers to the first element of this
-- list (see 'Grammar.Eval.evalTree').
type ArgTypes = [GType]

-- | Type outputted by the function.
type OutputType = GType

-- | Defines the arguments and output types for a function.
--
-- There is exactly one constructor, used with record syntax, so pattern
-- matching is always @MkFunctionType args out@ (or the @->>@ shorthand below).
data FunctionType = MkFunctionType
  { _argTypes :: !ArgTypes,
    _outType :: !OutputType
  }
  deriving (Show, Eq, Ord, Read, Generic)

-- | Defines the arguments and output types for the whole program.
--
-- An alias to make signatures that talk about \"the program being evolved\"
-- readable; a program is just a function from its inputs to its output.
type ProgramType = FunctionType

-- | List of types of the arguments expected by the program.
type ProgramArgTypes = ArgTypes

-- | A concrete representation of a value.
--
-- Note that 'LambdaLit' holds a whole 'TypedTree': a lambda is a value whose
-- body is itself a program. That is what makes this grammar
-- /higher-order/ - programs can build and consume other programs.
data Lit
  = IntLit !Int
  | FloatLit !Float
  | BoolLit !Bool
  | CharLit !Char
  | PairLit !Lit !Lit
  | -- | The 'GType' is the /element/ type of the list; it is stored so that
    -- an empty list still knows what it contains.
    ListLit !GType ![Lit]
  | -- | A lambda: a function value. @\_type@ is the lambda's signature and
    -- @\_tree@ its body, which uses @Arg 0@ as the lambda's parameter.
    LambdaLit !TypedTree
  deriving (Show, Eq, Read, Generic)

-- | Cached size information about a subtree: current depth (distance from
-- this node to the root), height, and total node count.
--
-- It is stored inside every node ('_measure') instead of being recomputed,
-- because the evolution loop queries tree sizes constantly (depth limits,
-- fitness heuristics, simplification) and recomputing would dominate the
-- runtime. The field is @Maybe@ because freshly built or mutated trees may
-- not have a valid measure yet; 'Grammar.Helpers.computeMeasure' fills it in.
data Measure = MkMeasure {_currentDepth :: !Int, _height :: !Int, _nodeCount :: !Int} deriving (Show, Eq, Read, Generic)

-- | Values that do not receive inputs - the leaves of a program.
data Terminal
  = -- | Reference to the n-th argument of the enclosing program/lambda
    -- (0-based). This is how a program says \"use my input\".
    Arg !Int
  | -- | A constant baked into the program.
    Literal !Lit
  deriving (Show, Eq, Read, Generic)

-- | The structure that represents a program written in this grammar.
--
-- A 'Tree' is either a 'Leaf' (a 'Terminal') or a 'Node' (an 'Operation'
-- together with the sub-trees feeding it). The '_measure' field is ignored
-- by all semantics - it is a memoised cache explained above.
--
-- Because 'Node' stores its children as a list, the arity of each operation
-- is implicit; it is fixed by 'Grammar.Types.opType' and assumed everywhere.
data Tree
  = Leaf {_measure :: !(Maybe Measure), _terminal :: !Terminal}
  | Node {_measure :: !(Maybe Measure), _operation :: !Operation, _args :: ![Tree]}
  deriving (Show, Eq, Read, Generic)

-- | A program combined with its expected inputs and output type.
--
-- Used for lambda bodies: the body must remember the type it was checked
-- against so that e.g. @map@ knows the element type of the result.
data TypedTree = MkTypedTree
  { _tree :: !Tree,
    _type :: !FunctionType
  }
  deriving (Show, Eq, Read, Generic)

-- | All available operations in this grammar.
--
-- This enum is the grammar itself: the search can never invent an operator
-- that is not listed here. Adding a new primitive means adding a constructor
-- here, its signature in 'Grammar.Types.opType', and its semantics in
-- 'Grammar.Eval.eval' (and, optionally, a pretty-printing rule in
-- "Grammar.Pretty" and rewrite rules in "Grammar.Simplify").
--
-- The list is intentionally small and total: every operation is defined for
-- all of its inputs, which keeps the type checker and evaluator simple.
data Operation
  = -- Int
    AddInt
  | SubInt
  | MultInt
  | DivInt
  | ModInt
  | MaxInt
  | MinInt
  | -- Bool
    And
  | Or
  | Not
  | If
  | -- Float
    AddFloat
  | SubFloat
  | MultFloat
  | DivFloat
  | Sqrt
  | -- Char + Bool
    EqChar
  | IsLetter
  | IsDigit
  | -- Float + Int
    IntToFloat
  | Floor
  | -- Int + Bool
    GtInt
  | LtInt
  | EqInt
  | -- Lists
    Len
  | Reverse
  | Singleton
  | Cons
  | Head
  | Range
  | Map
  | Filter
  | Concat
  | Zip
  | Take
  | SumFloats
  | ProductFloats
  | SumInts
  | ProductInts
  | -- String
    Unlines
  | ShowInt
  | -- Pair
    ToPair
  | Fst
  | Snd
  deriving (Show, Eq, Enum, Bounded, Ord, Read, Generic)

-- * Shorthands
--
-- The definitions below exist purely to make tree literals in tests, problem
-- definitions and the pruner readable. They are never part of the logic.

-- | Shorthand for 'Node' with an empty measure (to be computed later).
--
-- @AddInt <| [iLitT 1, arg 0]@ reads as \"1 + x0\" instead of
-- @Node Nothing AddInt [...]@.
(<|) :: Operation -> [Tree] -> Tree
(<|) = Node Nothing

-- | Shorthand for creating a function type: @'[GInt] ->> GInt'@ is
-- @Int -> Int@.
(->>) :: ArgTypes -> OutputType -> FunctionType
(->>) = MkFunctionType

-- | Shorthand for matching a literal leaf, e.g. @case t of LeafLit (IntLit n) -> ...@.
-- The bidirectional pattern also /builds/ such a leaf.
pattern LeafLit :: Lit -> Tree
pattern LeafLit a <- Leaf _ (Literal a) where LeafLit a = Leaf Nothing (Literal a)

-- | Shorthand for matching an argument leaf, e.g. @LeafArg 0@ is \"$0\".
pattern LeafArg :: Int -> Tree
pattern LeafArg i <- Leaf _ (Arg i) where LeafArg i = Leaf Nothing (Arg i)

-- Tells the exhaustiveness checker that every 'Tree' is covered by the two
-- patterns above plus 'Node', so case expressions using them need no fallback.
{-# COMPLETE LeafArg, LeafLit, Node #-}

-- | Composes a sequence of operations together, all applied to the same
-- leaves: @compOp [Not, Not] [t]@ is @not (not t)@.
--
-- Handy for writing chains of unary wrappers without nesting by hand.
compOp :: [Operation] -> [Tree] -> Tree
compOp [x] ts = x <| ts
compOp (x : xs) ts = x <| [compOp xs ts]
compOp _ _ = error "empty list on compOp!"
