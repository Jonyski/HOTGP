{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Module      : Grammar.Flat
--   Description : Compiles a 'Tree' into a linear stack-machine program.
--
-- Why this module exists
-- ----------------------
-- 'Grammar.Eval.evalTree' walks the heap-allocated 'Tree' recursively. That
-- is the wrong shape for a GPU (and a mediocre shape for a CPU too):
--
-- * every node is a separately allocated closure behind a pointer, so a
--   traversal is a chain of dependent memory loads - GPUs hide latency with
--   thousands of threads, not with pointer chasing;
-- * 'Maybe' plumbing and boxed 'Lit' values allocate on every internal node;
-- * a GPU kernel cannot call back into Haskell, so the program has to exist in
--   a data representation the kernel can read.
--
-- This module produces exactly that representation: a /postfix/ (reverse
-- Polish) instruction stream over a fixed-size value stack, plus a constant
-- pool. It is the same idea as the \"execution arrays\" used by Beagle, and it
-- is what @cbits/gp_flat_kernel.h@ executes on the device.
--
-- @
-- Node AddInt [Arg 0, LeafInt 1]   ==>   [ PushArg 0, PushConst 0, Apply AddInt ]
-- @
--
-- Semantics
-- ---------
-- 'evalFlat' is required to be observationally identical to 'evalTree' for
-- every program this module accepts. Two details make that non-trivial and are
-- the reason the code below is explicit about them:
--
-- * __Strict, left-to-right evaluation.__ 'evalTree' evaluates /all/ children
--   before applying the operator (@sequence@), so even @if@ evaluates both
--   branches. Postfix order is exactly that order (children left to right,
--   then the parent), so a crash happens at the same point.
--
-- * __NaN rejection.__ 'evalTree' turns a 'FloatLit' NaN produced /by an
--   operator/ into 'Nothing', but a NaN that is a literal or an argument goes
--   through untouched. Both evaluators reproduce that asymmetry.
--
-- What cannot be flattened
-- ------------------------
-- Only the /scalar/ part of the grammar is supported: 'GInt', 'GFloat',
-- 'GBool', 'GChar' and the operators over them. Lists, strings, pairs and
-- lambdas are rejected by 'flattenTree' ('Left' with a readable reason) and
-- the caller falls back to the interpreter. See @GPU.md@: those values have no
-- fixed size and the kernel has no heap.
--
-- The value layout is deliberately identical to the C structs in
-- @cbits/gp_flat_kernel.h@: a tag byte plus a 64-bit payload, with 32-bit
-- floats stored as their IEEE-754 bit pattern. That lets 'Benchmark.Gpu' feed
-- a kernel without any conversion pass.
module Grammar.Flat
  ( -- * Representation
    FlatInstr (..),
    FlatProgram (..),

    -- * Compilation
    flattenTree,

    -- * Execution (reference implementation)
    evalFlat,

    -- * The GPU-compatible subset of the grammar
    gpuSupported,
    gpuArity,
    scalarLit,

    -- * Value encoding
    valueTag,
    valueInt,
    valueFloat,
    valueBool,
    valueChar,
    floatBits,
    bitsFloat,
  )
where

import Control.Monad.ST (ST, runST)
import Data.Char (chr, ord)
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MVU
import Data.Word (Word8)
import GHC.Float (castFloatToWord32, castWord32ToFloat)
import Grammar.Core
import Grammar.Types (opArgTypes)

-- * Value tags
--
-- These numbers are part of the wire format: @cbits/gp_flat_kernel.h@ uses the
-- same ones, so never reorder them.

-- | Tag of an 'IntLit' payload.
valueInt :: Word8
valueInt = 0

-- | Tag of a 'FloatLit' payload (stored as its IEEE-754 bit pattern).
valueFloat :: Word8
valueFloat = 1

-- | Tag of a 'BoolLit' payload (0 or 1).
valueBool :: Word8
valueBool = 2

-- | Tag of a 'CharLit' payload (its code point).
valueChar :: Word8
valueChar = 3

-- | The tag the kernel uses for a scalar literal or argument, 'Nothing' if the
-- value has no fixed-size representation.
valueTag :: Lit -> Maybe Word8
valueTag IntLit {} = Just valueInt
valueTag FloatLit {} = Just valueFloat
valueTag BoolLit {} = Just valueBool
valueTag CharLit {} = Just valueChar
valueTag _ = Nothing

-- | A 'Float' as its 32-bit IEEE-754 pattern, widened to 'Int' so it can share
-- a slot with an 'Int' payload.
floatBits :: Float -> Int
floatBits = fromIntegral . castFloatToWord32

-- | The inverse of 'floatBits'.
bitsFloat :: Int -> Float
bitsFloat = castWord32ToFloat . fromIntegral

-- * The instruction set

-- | One instruction of the flattened program.
--
-- The stack discipline is implicit in the constructor: the two pushes push one
-- value, 'FApply' pops @'gpuArity' op@ values and pushes one.
data FlatInstr
  = -- | Push the /n/-th argument of the enclosing program (@Arg n@).
    FPushArg !Int
  | -- | Push the /n/-th entry of the constant pool.
    FPushConst !Int
  | -- | Pop the operator's arity values, apply it, push the result.
    FApply !Operation
  deriving (Eq, Show)

-- | A compiled program: instruction stream, constant pool and the stack size
-- it needs.
--
-- '_flatMaxStack' is computed at compile time, so the kernel can size its
-- stack as a plain local array - there is no dynamic allocation on the device.
data FlatProgram = MkFlatProgram
  { _flatInstrs :: !(V.Vector FlatInstr),
    -- | Literal constants, in the order the instructions refer to them.
    _flatConsts :: !(V.Vector Lit),
    -- | Maximum number of values alive on the stack at any point.
    _flatMaxStack :: !Int,
    -- | How many program arguments the tree refers to.
    _flatArity :: !Int
  }
  deriving (Eq, Show)

-- * Compilation

-- | Compiles a tree into a 'FlatProgram'.
--
-- Fails ('Left') with a reason when the tree uses anything outside the scalar
-- subset - a list operation, a list/string/pair/lambda literal, or an 'Arg'
-- index the program does not have. The caller falls back to
-- 'Grammar.Eval.evalTree' for those trees, which is what
-- 'Benchmark.Gpu.scorePopulation' does.
--
-- Constants are not deduplicated: an identical constant used twice gets two
-- pool slots. Deduplication would need an 'Ord' key over arbitrary 'Lit's and
-- save a handful of bytes, while the pool is tiny next to the arguments that a
-- real batch transfers.
--
-- The invariant that makes the stack accounting simple: every subtree leaves
-- exactly one value behind. So a child at index @k@ of an @n@-ary node starts
-- at depth @d + k@, and the peak is reached just before the operator runs
-- (@d + n@).
flattenTree ::
  -- | Number of arguments the enclosing program receives.
  Int ->
  Tree ->
  Either String FlatProgram
flattenTree nArgs tree = do
  -- Pass 1 validates the tree and sizes its vectors. Every node emits exactly
  -- one instruction and every literal leaf interns exactly one constant, so
  -- pass 2 can allocate the final vectors and fill them in place. Building a
  -- list and 'V.fromList'-ing it instead costs ~20x more than the evaluation
  -- it enables (229 ns/node against 9 ns/node), which would defeat the point.
  (nInstr, nConst, maxStack) <- sizeOf tree 0
  -- The evaluator sizes its stack array as maxStack + 1; refuse anything
  -- larger rather than letting the kernel run past its stack.
  if maxStack > maxStackLimit
    then Left $ "tree needs a stack of " <> show maxStack <> " values (limit " <> show maxStackLimit <> ")"
    else
      Right $
        runST $ do
          instrs <- MVU.new nInstr
          consts <- MVU.new nConst
          _ <- emit tree instrs consts 0 0
          frozenInstrs <- V.unsafeFreeze instrs
          frozenConsts <- V.unsafeFreeze consts
          pure
            MkFlatProgram
              { _flatInstrs = frozenInstrs,
                _flatConsts = frozenConsts,
                _flatMaxStack = maxStack,
                _flatArity = nArgs
              }
  where
    -- * Pass 1: validate and size

    -- @(instructions, constants, peak stack depth)@ for a subtree that starts
    -- with the stack @d@ values deep, or the reason it cannot be compiled.
    --
    -- The invariant that makes the stack accounting simple: every subtree
    -- leaves exactly one value behind. So child @k@ of an @n@-ary node starts
    -- at depth @d + k@, and the peak is reached just before the operator runs
    -- (@d + n@).
    sizeOf :: Tree -> Int -> Either String (Int, Int, Int)
    sizeOf (Leaf _ (Arg i)) d
      | i < 0 || i >= nArgs =
          Left $ "argument index " <> show i <> " is out of range for a program with " <> show nArgs <> " arguments"
      | otherwise = Right (1, 0, d + 1)
    sizeOf (Leaf _ (Literal lit)) d = case scalarLit lit of
      Nothing -> Left $ "non-scalar literal " <> show lit
      Just _ -> Right (1, 1, d + 1)
    sizeOf (Node _ op children) d
      | not (gpuSupported op) = Left $ "operation " <> show op <> " is not in the GPU subset"
      | nChildren /= gpuArity op =
          Left $ "operation " <> show op <> " expects " <> show (gpuArity op) <> " arguments, got " <> show nChildren
      | otherwise = do
          (is, cs, peak) <- sizeChildren d children 0 (0, 0, d)
          Right (is + 1, cs, max peak (d + gpuArity op))
      where
        nChildren = length children

    -- Sizes the children of an @n@-ary node that starts at depth @base@:
    -- child @k@ starts at @base + k@, because the @k@ earlier siblings have
    -- each left one value on the stack.
    sizeChildren :: Int -> [Tree] -> Int -> (Int, Int, Int) -> Either String (Int, Int, Int)
    sizeChildren _ [] _ acc = Right acc
    -- The accumulator is matched strictly: a depth-15 program is 100k+ nodes,
    -- and lazy @+@\/@max@ chains of that length cost more to build and force
    -- than the whole traversal.
    sizeChildren base (c : rest) k (!is, !cs, !peak) = do
      (i', c', peak') <- sizeOf c (base + k)
      sizeChildren base rest (k + 1) (is + i', cs + c', max peak peak')

    -- * Pass 2: fill

    -- Writes one subtree's instructions in postfix order (children left to
    -- right, then the parent) and its literals into the constant pool,
    -- returning the next instruction and constant slots.
    emit ::
      Tree ->
      MVU.MVector s FlatInstr ->
      MVU.MVector s Lit ->
      Int ->
      Int ->
      ST s (Int, Int)
    emit (Leaf _ (Arg i)) instrs _ iIdx kIdx = do
      MVU.unsafeWrite instrs iIdx (FPushArg i)
      pure (iIdx + 1, kIdx)
    emit (Leaf _ (Literal lit)) instrs consts iIdx kIdx = do
      MVU.unsafeWrite instrs iIdx (FPushConst kIdx)
      MVU.unsafeWrite consts kIdx lit
      pure (iIdx + 1, kIdx + 1)
    emit (Node _ op children) instrs consts iIdx kIdx = do
      (i', k') <- emitChildren children instrs consts iIdx kIdx
      MVU.unsafeWrite instrs i' (FApply op)
      pure (i' + 1, k')

    emitChildren [] _ _ iIdx kIdx = pure (iIdx, kIdx)
    emitChildren (c : rest) instrs consts iIdx kIdx = do
      (i', k') <- emit c instrs consts iIdx kIdx
      emitChildren rest instrs consts i' k'

    -- A depth-limited HOTGP tree needs at most height + 1 slots (a
    -- right-leaning chain of binary operators is the worst case, and height is
    -- capped at 15 by 'Evolution.Config'). The number must stay in sync with
    -- HGP_MAX_STACK in @cbits/gp_flat_kernel.h@: the kernel sizes its stack as
    -- a plain local array, so a deeper program cannot be run there.
    maxStackLimit :: Int
    maxStackLimit = 32

-- | The operators a GPU kernel can execute: everything whose values are
-- fixed-width scalars.
--
-- All list, string, pair and lambda operations are excluded. That is not a
-- shortcut of this implementation - those operations allocate, and a kernel
-- has no allocator. @GPU.md@ quantifies the resulting coverage per benchmark.
gpuSupported :: Operation -> Bool
gpuSupported AddInt = True
gpuSupported SubInt = True
gpuSupported MultInt = True
gpuSupported DivInt = True
gpuSupported ModInt = True
gpuSupported MaxInt = True
gpuSupported MinInt = True
gpuSupported And = True
gpuSupported Or = True
gpuSupported Not = True
gpuSupported If = True
gpuSupported AddFloat = True
gpuSupported SubFloat = True
gpuSupported MultFloat = True
gpuSupported DivFloat = True
gpuSupported Sqrt = True
gpuSupported EqChar = True
gpuSupported IsLetter = True
gpuSupported IsDigit = True
gpuSupported IntToFloat = True
gpuSupported Floor = True
gpuSupported GtInt = True
gpuSupported LtInt = True
gpuSupported EqInt = True
-- Lists, strings, pairs and lambdas: no fixed-size representation.
gpuSupported Len = False
gpuSupported Reverse = False
gpuSupported Singleton = False
gpuSupported Cons = False
gpuSupported Head = False
gpuSupported Range = False
gpuSupported Map = False
gpuSupported Filter = False
gpuSupported Concat = False
gpuSupported Zip = False
gpuSupported Take = False
gpuSupported SumFloats = False
gpuSupported ProductFloats = False
gpuSupported SumInts = False
gpuSupported ProductInts = False
gpuSupported Unlines = False
gpuSupported ShowInt = False
gpuSupported ToPair = False
gpuSupported Fst = False
gpuSupported Snd = False

-- | Number of values an operator consumes, taken from the grammar's own
-- signature table so it can never disagree with 'Grammar.Types.typeCheck'.
gpuArity :: Operation -> Int
gpuArity = length . opArgTypes

-- | 'Just' the literal if it is a scalar, 'Nothing' for lists, pairs and
-- lambdas.
--
-- An empty list is rejected too: it is the type, not the contents, that
-- decides whether the value has a fixed-width representation.
scalarLit :: Lit -> Maybe Lit
scalarLit lit@IntLit {} = Just lit
scalarLit lit@FloatLit {} = Just lit
scalarLit lit@BoolLit {} = Just lit
scalarLit lit@CharLit {} = Just lit
scalarLit _ = Nothing

-- * Reference execution

-- | Runs a 'FlatProgram' against one case's arguments.
--
-- This is the CPU reference of the kernel: same instruction stream, same stack
-- layout, same tag encoding. It is (a) a fast path that is already useful
-- without a GPU and (b) the oracle the CUDA kernel is differentially tested
-- against.
--
-- The stack is two unboxed vectors (tags and 64-bit payloads) sized from
-- '_flatMaxStack' and allocated once per case, which is why the operators read
-- and write raw payloads instead of pattern-matching on 'Lit'.
evalFlat :: FlatProgram -> [Lit] -> Maybe Lit
evalFlat prog args
  | flatArity > length args = Nothing
  | otherwise = runST run
  where
    instrs = _flatInstrs prog
    consts = _flatConsts prog
    nInstr = V.length instrs
    cap = _flatMaxStack prog + 1
    flatArity = _flatArity prog

    run :: forall s. ST s (Maybe Lit)
    run = do
      tags <- MVU.replicate cap valueInt
      vals <- MVU.replicate cap 0
      let go :: Int -> Int -> ST s (Maybe Lit)
          go !i !sp
            | i >= nInstr =
                -- A well-formed program leaves exactly one value; anything
                -- else means the instruction stream is inconsistent with the
                -- arities, which is a bug in 'flattenTree', not in the program.
                if sp /= 1
                  then pure Nothing
                  else do
                    t <- MVU.unsafeRead tags 0
                    v <- MVU.unsafeRead vals 0
                    pure $ Just (toLit t v)
            | otherwise = case instrs `V.unsafeIndex` i of
                FPushArg k -> case nthArg k of
                  Nothing -> pure Nothing
                  Just (t, v) -> push i t v sp
                FPushConst k -> case scalarValue (consts `V.unsafeIndex` k) of
                  Nothing -> pure Nothing
                  Just (t, v) -> push i t v sp
                FApply op -> stepOp op i sp
          push i t v sp = do
            MVU.unsafeWrite tags sp t
            MVU.unsafeWrite vals sp v
            go (i + 1) (sp + 1)

          -- Payload readers: `vals` holds every value, `iAt` reinterprets a
          -- slot as an 'Int', `fAt` as a 'Float'.
          iAt :: Int -> ST s Int
          iAt k = MVU.unsafeRead vals k

          fAt :: Int -> ST s Float
          fAt k = bitsFloat <$> MVU.unsafeRead vals k

          -- Executes one operator: reads its operands off the stack, computes
          -- @Just (tag, payload)@ or 'Nothing' on a runtime failure, and lets
          -- the common tail below do the bookkeeping.
          stepOp :: Operation -> Int -> Int -> ST s (Maybe Lit)
          stepOp op i sp = do
            let top = sp - 1
                second = sp - 2
                third = sp - 3
                -- The operator pops its arity and pushes one, so the result
                -- goes where the first (deepest) operand was.
                dst = sp - gpuArity op
            res <- case op of
              -- * Int
              AddInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueInt, fromIntegral (a + b))
              SubInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueInt, fromIntegral (a - b))
              MultInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueInt, fromIntegral (a * b))
              MaxInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueInt, fromIntegral (max a b))
              MinInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueInt, fromIntegral (min a b))
              DivInt -> do
                b <- iAt top
                a <- iAt second
                pure $
                  if b == 0
                    then Nothing
                    else
                      if b == (-1)
                        then -- 'eval' special-cases `x `div` -1` because
                        -- `minBound `div` -1` overflows.
                          Just (valueInt, fromIntegral (negate a))
                        else Just (valueInt, fromIntegral (a `div` b))
              ModInt -> do
                b <- iAt top
                a <- iAt second
                -- Haskell's `mod` takes the sign of the divisor; C's `%` does
                -- not, so the kernel implements this rule explicitly.
                pure $ if b == 0 then Nothing else Just (valueInt, fromIntegral (a `mod` b))
              -- * Bool
              And -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueBool, if a /= 0 && b /= 0 then 1 else 0)
              Or -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueBool, if a /= 0 || b /= 0 then 1 else 0)
              Not -> do
                a <- iAt top
                pure $ Just (valueBool, if a == 0 then 1 else 0)
              If -> do
                cond <- iAt third
                bt <- MVU.unsafeRead tags second
                bv <- MVU.unsafeRead vals second
                et <- MVU.unsafeRead tags top
                ev <- MVU.unsafeRead vals top
                -- Both branches were already evaluated (call-by-value); this
                -- only selects. The NaN rule still applies to the result.
                pure $ Just (if cond /= 0 then (bt, bv) else (et, ev))
              -- * Float
              AddFloat -> do
                b <- fAt top
                a <- fAt second
                pure $ Just (valueFloat, floatBits (a + b))
              SubFloat -> do
                b <- fAt top
                a <- fAt second
                pure $ Just (valueFloat, floatBits (a - b))
              MultFloat -> do
                b <- fAt top
                a <- fAt second
                pure $ Just (valueFloat, floatBits (a * b))
              DivFloat -> do
                b <- fAt top
                a <- fAt second
                pure $ if b == 0 then Nothing else Just (valueFloat, floatBits (a / b))
              Sqrt -> do
                a <- fAt top
                -- 'eval' takes the absolute value to stay on the real domain.
                pure $ Just (valueFloat, floatBits (sqrt (abs a)))
              -- * Char + Bool
              EqChar -> do
                b <- MVU.unsafeRead vals top
                a <- MVU.unsafeRead vals second
                pure $ Just (valueBool, if a == b then 1 else 0)
              IsLetter -> do
                c <- (chr . fromIntegral) <$> MVU.unsafeRead vals top
                -- ASCII letters only: the datasets are ASCII, and this keeps
                -- the result locale-independent (and identical in the kernel).
                pure $ Just (valueBool, if (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') then 1 else 0)
              IsDigit -> do
                c <- (chr . fromIntegral) <$> MVU.unsafeRead vals top
                pure $ Just (valueBool, if c >= '0' && c <= '9' then 1 else 0)
              -- * Float + Int
              IntToFloat -> do
                a <- iAt top
                pure $ Just (valueFloat, floatBits (fromIntegral a))
              Floor -> do
                a <- fAt top
                pure $ Just (valueInt, floor a)
              -- * Int + Bool
              GtInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueBool, if a > b then 1 else 0)
              LtInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueBool, if a < b then 1 else 0)
              EqInt -> do
                b <- iAt top
                a <- iAt second
                pure $ Just (valueBool, if a == b then 1 else 0)
              -- 'flattenTree' rejects everything else, so this is unreachable
              -- for a program produced by this module.
              _ -> pure Nothing
            case res of
              Nothing -> pure Nothing
              Just (t, v)
                -- The NaN rule: an operator that produced NaN fails, exactly
                -- like the `guard` in 'Grammar.Eval.evalTree'.
                | t == valueFloat && isNaN (bitsFloat v) -> pure Nothing
                | otherwise -> do
                    MVU.unsafeWrite tags dst t
                    MVU.unsafeWrite vals dst v
                    go (i + 1) (dst + 1)
      -- Start at the first instruction with an empty stack.
      go 0 0

    -- Reads a scalar literal into the (tag, payload) pair used on the stack.
    scalarValue :: Lit -> Maybe (Word8, Int)
    scalarValue lit = case lit of
      IntLit x -> Just (valueInt, fromIntegral x)
      FloatLit x -> Just (valueFloat, floatBits x)
      BoolLit x -> Just (valueBool, if x then 1 else 0)
      CharLit c -> Just (valueChar, ord c)
      _ -> Nothing

    nthArg :: Int -> Maybe (Word8, Int)
    nthArg k = scalarValue (args !! k)

    toLit :: Word8 -> Int -> Lit
    toLit t v
      | t == valueInt = IntLit v
      | t == valueFloat = FloatLit (bitsFloat v)
      | t == valueBool = BoolLit (v /= 0)
      | otherwise = CharLit (chr v)
