/*
 * gp_flat_kernel.h - the GPU-side evaluator for flattened HOTGP programs.
 *
 * This header is the C counterpart of src/Grammar/Flat.hs. It is written in
 * the subset of C++ that both nvcc and g++ accept, so the exact same code that
 * runs on the device can be compiled and executed on the CPU (see
 * gpu/gp_eval_cpu.cpp). That is how the kernel is verified on a machine
 * without a GPU: the CPU build is differentially tested against the Haskell
 * reference evaluator, and the CUDA build only adds the launch around it.
 *
 * Design notes
 * ------------
 *  - A program is a postfix instruction stream over a fixed-size value stack.
 *    No pointers, no allocation, no recursion: a thread walks a flat array.
 *  - Values are a tag plus a 64-bit payload. Ints are 64-bit (Haskell's Int),
 *    floats are 32-bit (Haskell's Float) stored as their IEEE-754 bit pattern,
 *    bools are 0/1 and chars are their code point. The layout matches the wire
 *    format in src/Benchmark/Gpu/Protocol.hs.
 *  - A runtime failure (division by zero, NaN produced by an operator) makes
 *    the whole case fail, exactly like `Nothing` in Grammar.Eval.evalTree.
 *    There is no exception handling and no recovery: the interpreter has none
 *    either.
 *  - Semantics that are easy to get wrong and are therefore spelled out:
 *      * `div`/`mod` follow Haskell's rules (round toward -infinity, sign of
 *        the divisor), not C's truncating `/` and `%`;
 *      * `x `div` -1` is special-cased to `negate x` (the interpreter does
 *        this to dodge the minBound overflow);
 *      * `sqrt` takes the absolute value (the interpreter does);
 *      * `if` evaluates both branches (call-by-value in the interpreter), so
 *        the stack machine simply selects one of two already-computed values;
 *      * NaN is rejected only when an *operator* produces it, never for a
 *        literal or an argument - the interpreter's asymmetry.
 *  - Do not compile with --use_fast_math: it would change division, sqrt and
 *    NaN behaviour and silently break parity with the interpreter.
 */
#ifndef HGP_FLAT_KERNEL_H
#define HGP_FLAT_KERNEL_H

#include <stdint.h>
#include <string.h>
#include <math.h>

#ifdef __CUDACC__
#define HGP_DEVICE __device__ __forceinline__
#else
#define HGP_DEVICE static inline
#endif

/* ------------------------------------------------------------------ */
/* Value tags - must match Grammar.Flat.valueInt/valueFloat/...        */
/* ------------------------------------------------------------------ */
#define HGP_TAG_INT 0u
#define HGP_TAG_FLOAT 1u
#define HGP_TAG_BOOL 2u
#define HGP_TAG_CHAR 3u
/* Sentinel for a non-scalar argument (list, pair, lambda), see
 * Benchmark.Gpu.Protocol.nonScalarTag. Pushing one is a failure: a well-typed
 * scalar program never reads a list argument. */
#define HGP_TAG_NON_SCALAR 0xffu

/* ------------------------------------------------------------------ */
/* Opcodes - must match Benchmark.Gpu.Protocol.opCode                  */
/*                                                                     */
/* Operators are encoded as HGP_OP_BASE + the position of the          */
/* constructor in Grammar.Core.Operation. The names below are that     */
/* order, spelled out so a mismatch is visible in review.              */
/* ------------------------------------------------------------------ */
#define HGP_OP_PUSH_ARG 0u
#define HGP_OP_PUSH_CONST 1u
#define HGP_OP_BASE 2u

#define HGP_ADD_INT (HGP_OP_BASE + 0u)
#define HGP_SUB_INT (HGP_OP_BASE + 1u)
#define HGP_MULT_INT (HGP_OP_BASE + 2u)
#define HGP_DIV_INT (HGP_OP_BASE + 3u)
#define HGP_MOD_INT (HGP_OP_BASE + 4u)
#define HGP_MAX_INT (HGP_OP_BASE + 5u)
#define HGP_MIN_INT (HGP_OP_BASE + 6u)
#define HGP_AND (HGP_OP_BASE + 7u)
#define HGP_OR (HGP_OP_BASE + 8u)
#define HGP_NOT (HGP_OP_BASE + 9u)
#define HGP_IF (HGP_OP_BASE + 10u)
#define HGP_ADD_FLOAT (HGP_OP_BASE + 11u)
#define HGP_SUB_FLOAT (HGP_OP_BASE + 12u)
#define HGP_MULT_FLOAT (HGP_OP_BASE + 13u)
#define HGP_DIV_FLOAT (HGP_OP_BASE + 14u)
#define HGP_SQRT (HGP_OP_BASE + 15u)
#define HGP_EQ_CHAR (HGP_OP_BASE + 16u)
#define HGP_IS_LETTER (HGP_OP_BASE + 17u)
#define HGP_IS_DIGIT (HGP_OP_BASE + 18u)
#define HGP_INT_TO_FLOAT (HGP_OP_BASE + 19u)
#define HGP_FLOOR (HGP_OP_BASE + 20u)
#define HGP_GT_INT (HGP_OP_BASE + 21u)
#define HGP_LT_INT (HGP_OP_BASE + 22u)
#define HGP_EQ_INT (HGP_OP_BASE + 23u)
/* 24..43 are the list/string/pair operations. They are never emitted by
 * Grammar.Flat.flattenTree (it rejects them), so the kernel does not
 * implement them: reaching one means the host sent a program it should have
 * filtered, and the case fails. */

/* ------------------------------------------------------------------ */
/* Data layout                                                         */
/* ------------------------------------------------------------------ */

/* Maximum stack depth. Must equal Grammar.Flat's maxStackLimit. A depth-15
 * tree needs at most height+1 = 16 slots; 32 leaves headroom and keeps the
 * per-thread local array at 32 * 16 = 512 bytes. */
#define HGP_MAX_STACK 32

/* One instruction: opcode plus its argument (index for the pushes). */
typedef struct {
  uint32_t op;
  uint32_t arg;
} HGPInstr;

/* One value: tag plus a 64-bit payload. 16 bytes, 8-byte aligned. */
typedef struct {
  uint64_t bits;
  uint32_t tag;
  uint32_t pad;
} HGPVal;

/* One result record, identical to the wire format's response record. */
typedef struct {
  uint32_t ok;
  uint32_t tag;
  uint64_t bits;
} HGPOut;

/* ------------------------------------------------------------------ */
/* Bit-level helpers                                                   */
/* ------------------------------------------------------------------ */

HGP_DEVICE float hgp_bits_to_float(uint64_t bits) {
  uint32_t w = (uint32_t)bits;
  float f;
  memcpy(&f, &w, sizeof(f));
  return f;
}

HGP_DEVICE uint64_t hgp_float_to_bits(float f) {
  uint32_t w;
  memcpy(&w, &f, sizeof(w));
  return (uint64_t)w;
}

/* Haskell's `div`: rounds toward negative infinity. */
HGP_DEVICE int64_t hgp_hs_div(int64_t a, int64_t b) {
  int64_t q = a / b;
  int64_t r = a % b;
  if (r != 0 && ((r < 0) != (b < 0))) q -= 1;
  return q;
}

/* Haskell's `mod`: the result takes the sign of the divisor. */
HGP_DEVICE int64_t hgp_hs_mod(int64_t a, int64_t b) {
  int64_t r = a % b;
  if (r != 0 && ((r < 0) != (b < 0))) r += b;
  return r;
}

/* ------------------------------------------------------------------ */
/* The evaluator                                                       */
/* ------------------------------------------------------------------ */

/*
 * Runs one program on one case.
 *
 *   code/nInstr   the program's instruction stream
 *   consts/nConst its constant pool
 *   args/nArgs    the case's arguments (Arg 0 .. Arg nArgs-1)
 *   out           receives the result when the function returns true
 *
 * Returns false when the program crashed on this case (the interpreter's
 * Nothing). The caller turns that into an `ok = 0` record.
 *
 * One thread per (program, case) is the mapping used by the CUDA runner: a
 * block is one organism and its threads are that organism's fitness cases,
 * which is the mapping described in the Beagle paper.
 */
HGP_DEVICE bool hgp_eval_case(const HGPInstr *code, uint32_t nInstr,
                              const HGPVal *consts, uint32_t nConst,
                              const HGPVal *args, uint32_t nArgs,
                              HGPVal *out) {
  HGPVal st[HGP_MAX_STACK];
  uint32_t sp = 0;

  for (uint32_t i = 0; i < nInstr; ++i) {
    const uint32_t op = code[i].op;
    const uint32_t arg = code[i].arg;

    if (op == HGP_OP_PUSH_ARG) {
      if (arg >= nArgs || sp >= HGP_MAX_STACK) return false;
      if (args[arg].tag > HGP_TAG_CHAR) return false; /* non-scalar argument */
      st[sp++] = args[arg];
      continue;
    }
    if (op == HGP_OP_PUSH_CONST) {
      if (arg >= nConst || sp >= HGP_MAX_STACK) return false;
      st[sp++] = consts[arg];
      continue;
    }

    /* Every operator below pops its arity and pushes one value, so the
     * stack must hold at least that many. A well-formed program always
     * satisfies this; the check keeps a malformed one from reading garbage. */
    switch (op) {
      /* ---------------- Int ---------------- */
      case HGP_ADD_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_INT;
        /* Unsigned arithmetic: Haskell's Int wraps on overflow, C's signed
         * overflow is undefined behaviour. */
        st[sp - 1].bits = (uint64_t)a + (uint64_t)b;
        break;
      }
      case HGP_SUB_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_INT;
        st[sp - 1].bits = (uint64_t)a - (uint64_t)b;
        break;
      }
      case HGP_MULT_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_INT;
        st[sp - 1].bits = (uint64_t)a * (uint64_t)b;
        break;
      }
      case HGP_DIV_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        if (b == 0) return false;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_INT;
        /* `x `div` -1` is negate x in the interpreter (avoids the minBound
         * overflow), and it also keeps hgp_hs_div away from INT64_MIN / -1. */
        st[sp - 1].bits = (b == -1) ? (uint64_t)(0 - (uint64_t)a) : (uint64_t)hgp_hs_div(a, b);
        break;
      }
      case HGP_MOD_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        if (b == 0) return false;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_INT;
        st[sp - 1].bits = (uint64_t)hgp_hs_mod(a, b);
        break;
      }
      case HGP_MAX_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_INT;
        st[sp - 1].bits = (uint64_t)(a > b ? a : b);
        break;
      }
      case HGP_MIN_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_INT;
        st[sp - 1].bits = (uint64_t)(a < b ? a : b);
        break;
      }

      /* ---------------- Bool ---------------- */
      case HGP_AND: {
        if (sp < 2) return false;
        uint64_t b = st[sp - 1].bits;
        uint64_t a = st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_BOOL;
        st[sp - 1].bits = (a != 0 && b != 0) ? 1u : 0u;
        break;
      }
      case HGP_OR: {
        if (sp < 2) return false;
        uint64_t b = st[sp - 1].bits;
        uint64_t a = st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_BOOL;
        st[sp - 1].bits = (a != 0 || b != 0) ? 1u : 0u;
        break;
      }
      case HGP_NOT: {
        if (sp < 1) return false;
        uint64_t a = st[sp - 1].bits;
        st[sp - 1].tag = HGP_TAG_BOOL;
        st[sp - 1].bits = (a == 0) ? 1u : 0u;
        break;
      }
      case HGP_IF: {
        if (sp < 3) return false;
        /* Both branches are already on the stack: the interpreter evaluates
         * them eagerly, so this only selects. */
        uint64_t cond = st[sp - 3].bits;
        HGPVal chosen = (cond != 0) ? st[sp - 2] : st[sp - 1];
        sp -= 2;
        st[sp - 1] = chosen;
        /* The NaN rule applies to the operator's result, as in the
         * interpreter (which checks the value `if` returns). */
        if (chosen.tag == HGP_TAG_FLOAT && isnan(hgp_bits_to_float(chosen.bits))) return false;
        break;
      }

      /* ---------------- Float ---------------- */
      case HGP_ADD_FLOAT:
      case HGP_SUB_FLOAT:
      case HGP_MULT_FLOAT:
      case HGP_DIV_FLOAT: {
        if (sp < 2) return false;
        float b = hgp_bits_to_float(st[sp - 1].bits);
        float a = hgp_bits_to_float(st[sp - 2].bits);
        float r;
        if (op == HGP_ADD_FLOAT) r = a + b;
        else if (op == HGP_SUB_FLOAT) r = a - b;
        else if (op == HGP_MULT_FLOAT) r = a * b;
        else {
          if (b == 0.0f) return false; /* DivFloat guards zero */
          r = a / b;
        }
        if (isnan(r)) return false;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_FLOAT;
        st[sp - 1].bits = hgp_float_to_bits(r);
        break;
      }
      case HGP_SQRT: {
        if (sp < 1) return false;
        float a = hgp_bits_to_float(st[sp - 1].bits);
        float r = sqrtf(fabsf(a));
        if (isnan(r)) return false;
        st[sp - 1].tag = HGP_TAG_FLOAT;
        st[sp - 1].bits = hgp_float_to_bits(r);
        break;
      }

      /* ---------------- Char + Bool ---------------- */
      case HGP_EQ_CHAR: {
        if (sp < 2) return false;
        uint64_t b = st[sp - 1].bits;
        uint64_t a = st[sp - 2].bits;
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_BOOL;
        st[sp - 1].bits = (a == b) ? 1u : 0u;
        break;
      }
      case HGP_IS_LETTER: {
        if (sp < 1) return false;
        int64_t c = (int64_t)st[sp - 1].bits;
        /* ASCII only, locale-independent: matches the Haskell reference,
         * which deliberately restricts itself to ASCII for parity. */
        bool letter = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z');
        st[sp - 1].tag = HGP_TAG_BOOL;
        st[sp - 1].bits = letter ? 1u : 0u;
        break;
      }
      case HGP_IS_DIGIT: {
        if (sp < 1) return false;
        int64_t c = (int64_t)st[sp - 1].bits;
        bool digit = (c >= '0' && c <= '9');
        st[sp - 1].tag = HGP_TAG_BOOL;
        st[sp - 1].bits = digit ? 1u : 0u;
        break;
      }

      /* ---------------- Float + Int ---------------- */
      case HGP_INT_TO_FLOAT: {
        if (sp < 1) return false;
        int64_t a = (int64_t)st[sp - 1].bits;
        st[sp - 1].tag = HGP_TAG_FLOAT;
        st[sp - 1].bits = hgp_float_to_bits((float)a);
        break;
      }
      case HGP_FLOOR: {
        if (sp < 1) return false;
        float a = hgp_bits_to_float(st[sp - 1].bits);
        st[sp - 1].tag = HGP_TAG_INT;
        st[sp - 1].bits = (uint64_t)(int64_t)floorf(a);
        break;
      }

      /* ---------------- Int + Bool ---------------- */
      case HGP_GT_INT:
      case HGP_LT_INT:
      case HGP_EQ_INT: {
        if (sp < 2) return false;
        int64_t b = (int64_t)st[sp - 1].bits;
        int64_t a = (int64_t)st[sp - 2].bits;
        bool r = (op == HGP_GT_INT) ? (a > b) : (op == HGP_LT_INT) ? (a < b) : (a == b);
        sp -= 1;
        st[sp - 1].tag = HGP_TAG_BOOL;
        st[sp - 1].bits = r ? 1u : 0u;
        break;
      }

      default:
        /* A list/string/pair operation, or an unknown opcode: the host should
         * have filtered this program out. Fail the case rather than guess. */
        return false;
    }
  }

  if (sp != 1) return false;
  *out = st[0];
  return true;
}

#endif /* HGP_FLAT_KERNEL_H */
