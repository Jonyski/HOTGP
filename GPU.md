# GPU-accelerated fitness evaluation in HOTGP

This document answers the question *"can HOTGP use the GPU to evaluate a
population's fitness in parallel, like the Beagle/GPU-GP work does?"* — what was
implemented, what was measured, and where the GPU actually pays off in this
particular engine.

**Short answer:** yes for the **initial population**, no for the steady-state
loop's per-step evaluations. HOTGP has no "generation" to parallelise: it breeds
one pair of children at a time and scores them immediately. The one place where
a whole population of programs is scored at once is `initPop` — 1000 programs ×
N training cases — and that is precisely the shape a GPU likes. That path is
implemented here, and it is exercised end to end (`--gpu` on the CLI).

Everything below is reproducible; see [§10](#10-building-and-running).

---

## 1. What HOTGP actually evaluates

From `src/Benchmark/BenchmarkToConfig.hs` and `src/Evolution/Run.hs`:

| parameter | value | meaning |
|---|---|---|
| `_popSize` | 1000 | population size |
| `_individualsPerStep` | 2 | parents sampled per iteration |
| `_nEvaluations` | `300 * popSize` = 300 000 | evaluation budget |
| tree depth | 15 | so programs can be ~10⁵ nodes |

The loop is **steady-state**, not generational:

```
sample 2 parents → 1 pair → crossover? → mutate → de-duplicate → score children → keep best 1000
```

One iteration therefore evaluates **at most two programs** (~150 000 iterations
per run). Two (program, case) pairs are three orders of magnitude too little to
amortise a kernel launch, let alone a host↔device transfer. Batching the *step*
is not a matter of code structure: there is no batch in the algorithm.

`initPop`, by contrast, generates `popSize` trees and scores each one:
**1000 trees × trainCases cases**, e.g. 100 000 evaluations for a 100-case
problem, at once. This is the batch this implementation targets.

Two facts about the serial path matter for everything that follows, and both
were discovered by measuring rather than by reading:

1. **Programs are big.** At depth 15 the median `popSize` for the `median`
   problem is 9.4 M nodes (≈ 9 400 nodes per program), and a single tree can
   reach 200 000 nodes.
2. **Scoring short-circuits on crashes.** `outputsFitness` folds the per-case
   results with `mconcat` over `Result a`, whose `Semigroup` propagates
   `Error`; because the fold is lazy, evaluation stops at the **first crashing
   case**. Measured on the initial population: only **36.8 of 100** cases are
   touched for `median`, and 29.2 of 100 for `smallest`.

Consequence 2 is the reason a *CPU* batch is slower than the serial loop (§6),
and it is the reason a GPU batch has to be judged on throughput, not on "same
work, more cores".

---

## 2. What the paper does, and the mapping onto HOTGP

The GPU-GP paper (Beagle, C#/CUDA) compiles each program into a linear array of
instructions and launches **one block per program, one thread per fitness
case**: each thread runs the whole program on its own training case, so a block
scores one program completely and blocks are independent.

HOTGP's fitness function has exactly that structure — run one tree per training
case, apply the metric, aggregate — so the mapping carries over unchanged:

```
grid.x  = program index      (one CUDA block per organism)
thread  = training case      (one thread per (program, case) evaluation)
```

The differences are all on the host side: HOTGP's programs are immutable
Haskell trees with a typed grammar, its fitness types are arbitrary `Monoid`s,
and its interpreter has carefully specified semantics (`div`/`mod` rounding, NaN
rejection asymmetry, eager `if`, crash-poisons-the-score) that must survive the
port. Those are what the modules below handle.

---

## 3. What was implemented

```
                        Haskell (host)                          C/CUDA (gpu/)
  Tree ──flattenTree──▶ FlatProgram ──encodeBatch──▶ HGB1 request ──▶ gp_eval / gp_eval_cpu
   │                        │                                              │
   │                        └──evalFlat (CPU reference)                    │
   │                                                                       ▼
   └──── outputsFitness ◀── decodeOutputs ◀── HGX1 response ◀── hgp_eval_case (one per case)
```

| file | role |
|---|---|
| `src/Grammar/Flat.hs` | compiles a `Tree` into a postfix stack-machine `FlatProgram`; rejects anything outside the scalar subset; contains `evalFlat`, the in-process reference evaluator that shares the kernel's instruction set |
| `src/Benchmark/Gpu/Protocol.hs` | the binary batch format (`HGB1`/`HGX1`), 8 bytes per instruction, 12 bytes per constant |
| `src/Benchmark/Gpu.hs` | `scorePopulation` / `populationBatch`, the `Backend` choice (`CpuReference` or `ExternalRunner exe`), interpreter fallback for unflattenable trees, and `BatchScorer` for the run loop |
| `src/Evolution/Run.hs` | `initPopBatched` / `runAndLogWith` — the run loop with a pluggable population scorer (`serialScorer` is the old behaviour) |
| `src/Benchmark/Run.hs`, `Benchmark/Problems.hs`, `app/Main.hs` | `--gpu` / `--gpu-cpu` plumbing; the batch statistics are printed when the population is scored |
| `cbits/gp_flat_kernel.h` | **the kernel**: `hgp_eval_case`, one postfix interpreter shared by the CUDA and C++ builds |
| `gpu/gp_eval.cu` | CUDA runner: read batch → upload → one block per program, one thread per case → download → write results |
| `gpu/gp_eval_cpu.cpp` | the same kernel compiled as C++, so the GPU path can be verified (and used) without a GPU |
| `gpu/Makefile`, `gpu/verify_parity.sh` | build (`make`, `make cpu`) and the parity check |
| `test/GpuSpec.hs` | differential tests: flattened vs interpreter, batched vs serial fitness, kernel vs reference, run-loop integration |
| `bench/Perf.hs` (`hotgp-perf gpu`) | the coverage/speed harness that produced §6 |

### 3.1 Why flatten at all

`evalTree` walks a heap-allocated tree of closures. On a GPU that is a chain of
dependent memory loads and, worse, it cannot exist: a kernel cannot call back
into Haskell. So every tree is compiled once into a **postfix instruction
stream over a fixed-size value stack**:

```
Node AddInt [Arg 0, LeafInt 1]   ==>   [ PushArg 0, PushConst 0, Apply AddInt ]
```

No allocation, no recursion, no pointers on the device: a thread walks a flat
array with an integer stack pointer. The maximum stack depth is computed at
compile time, so the kernel's stack is a plain local array (`HGP_MAX_STACK`,
32 entries), which is what keeps the kernel register-friendly.

The compiler does two passes — one to validate and size the vectors, one to fill
them in place. The first version built lists and called `V.fromList`, which cost
~20× more than the evaluation it enabled (229 ns/node against 9 ns/node); see
§6.3. That is also why `evaluation cost` is quoted per **node** rather than per
tree: it is the only unit that transfers to the GPU.

### 3.2 The supported subset

Only programs over fixed-width scalars compile:

| supported | rejected (fall back to the interpreter) |
|---|---|
| `Int`, `Float`, `Bool`, `Char` operators (`AddInt` … `EqInt`, `If`, `Sqrt`, `Floor`, `IntToFloat`, `IsLetter`, `IsDigit`, `EqChar`) | every list/string/pair operation (`Len`, `Map`, `Filter`, `Concat`, `Unlines`, `ToPair`, `Fst`, …), non-scalar literals, lambdas |

That is not an implementation shortcut: lists and strings have no fixed size
and a kernel has no allocator. §6.1 quantifies the resulting coverage — it is
100 % for the classic numeric benchmarks and ~0 % of the *nodes* for the
list/string ones.

`scorePopulation` handles the split transparently: trees that do not compile
are scored by `evalTree` exactly as before, and the final fitness is computed by
**one shared function** (`outputsFitness`) for both sides, so a population's
scores do not depend on which side of the split a tree landed on.

### 3.3 Why a subprocess instead of FFI

`ExternalRunner` writes the batch to a temp file, runs the runner, and reads the
reply. Per batch this costs one process spawn (~5 ms) and the file I/O — utterly
negligible for one `initPop`, and it keeps the entire GPU toolchain (nvcc, CUDA
runtime, stub libraries, linker flags) out of the Haskell build: `cabal build`
never needs CUDA, and the C++ twin gives a GPU-free implementation of the same
backend. §8 explains when that trade-off flips.

---

## 4. Semantics: why the numbers are identical, not merely close

`evalFlat` and `hgp_eval_case` were written against `Grammar.Eval.evalTree` and
are required to be observationally identical, including:

* **Strict, left-to-right evaluation of all children** — postfix order *is* that
  order, so `if` evaluates both branches, and a crash happens at the same point;
* **`div`/`mod`** follow Haskell's rules (round toward −∞, sign of the divisor),
  not C's truncating `/` and `%`; `x div -1` is special-cased to `negate x`, as
  the interpreter does to dodge the `minBound` overflow;
* **`sqrt` of a negative number** takes the absolute value, as the interpreter
  does; `floor` on NaN is a failure;
* **NaN asymmetry** — a NaN produced *by an operator* fails the case, a NaN that
  is a literal or an argument passes through;
* **the metric and its aggregation never move to the device**. The GPU returns
  raw per-case values; `outputsFitness` turns them into a fitness, so
  floating-point summation order and the "one crash poisons the score" rule are
  the same code on both paths.

---

## 5. Tests

`test/GpuSpec.hs` (run via `cabal test`, or `./gpu/verify_parity.sh` for the
kernel part) covers four layers:

| layer | test | what it pins down |
|---|---|---|
| flatten | *matches the interpreter on every scalar operator* | every opcode, div/mod signs, div-by-zero, NaN, eager `if`, stack-depth accounting |
| flatten | *random populations match the interpreter* | 40 QuickCheck populations from the real sampler, evaluated on random arguments |
| batch | *median / smallest / number-io: batched == interpreter* | `populationBatch` reproduces `_fitnessFunction` exactly, with 100 % eligibility |
| run loop | *initPopBatched == initPop for the same seed* | the batched initial population is the *same population*: same trees, same fitnesses |
| external | *gpu/gp_eval_cpu matches the CPU reference* | the kernel source, its opcode table and the wire format agree with the Haskell side (skipped if the binary is not built) |

The GPU group passes consistently (12 consecutive runs of `-p GPU`). The full
suite is 199 tests; note that one **pre-existing** QuickCheck property in
`test/GrammarSpec.hs` (`Mirror Image`, a hand-written Koza tree compared against
`x == reverse y`) fails on roughly one run in four for inputs such as
`[[1], [-2, 1]]`. It exercises `evalTree` and a hard-coded tree only, is
unrelated to this work, and was left untouched; `-p '!/Mirror Image/'` runs the
other 198 green.

The kernel is verified through its C++ build: `cbits/gp_flat_kernel.h` is written
in the subset of C++ that both `nvcc` and `g++` accept, and `gp_eval.cu` adds
only the grid/thread mapping, the four `cudaMemcpy`s and the launch. The
differential test therefore exercises the exact code that would run on the
device, on a machine without one.

---

## 6. Measurements

Machine: this container, no GPU (see §9), one core (`taskset -c 2`, `+RTS -N1`),
GHC 9.6.7 `-O2`. Reproduce with `cabal bench hotgp-perf --benchmark-options='gpu'`
(or `hotgp-perf gpu <problem...>`).

### 6.1 Coverage of the scalar subset (initial population, seed 1, popSize 1000)

| problem | train cases | trees flattenable | nodes flattenable |
|---|---|---|---|
| `median` | 100 | **100.0 %** | **100.0 %** |
| `smallest` | 100 | **100.0 %** | **100.0 %** |
| `number-io` | 250 | **100.0 %** | **100.0 %** |
| `sum-of-squares` | 50 | 20.3 % | 0.1 % |
| `count-odds` | 200 | 17.5 % | 0.0 % |
| `wallis-pi` | 150 | 11.2 % | 0.1 % |

Two conclusions, both important:

* the subset covers **all** of the purely numeric benchmarks — the ones whose
  programs are also the most expensive to evaluate;
* for the list/string benchmarks it covers essentially none of the *work*
  (0.0–0.1 % of nodes), because those programs are dominated by a handful of
  enormous list-building subtrees. A GPU cannot help those at all.

No tree in any of those populations was rejected by the 32-slot stack bound; the
bound only bites on pathologically deep spines, which the depth-15 sampler does
not produce here.

### 6.2 Scoring the same 1000-tree population: serial vs batched (CPU reference)

Same trees, same seed, same metric. `serial` = `map (mkIndividual cfg)`,
`batched` = `populationBatch CpuReference` (flatten + `evalFlat` + aggregate).

| problem | nodes | avg cases touched before crash | serial | batched | ratio |
|---|---|---|---|---|---|
| `median` | 9.43 M | 36.8 / 100 | **3.73 s** | 20.72 s | 0.18× |
| `smallest` | 9.47 M | 29.2 / 100 | **9.02 s** | 21.86 s | 0.41× |
| `number-io` | 0.92 M | 132.2 / 250 | **0.87 s** | 0.81 s | 1.07× |

**On the CPU, batching loses** — badly for the problems that short-circuit most.
This is not a defect of the flattening; it is the cost of the two properties a
batch cannot have:

1. it evaluates **every case** of every program (a GPU cannot stop a grid
   mid-launch because one block divided by zero), while the serial fold stops at
   the first crash — 2.7× more work for `median`, 3.4× for `smallest`;
2. it pays the flattening pass (see §6.3) before the first case runs.

`CpuReference` therefore exists as the **oracle** for the kernel and as a
plumbing check (`--gpu-cpu`), not as an optimisation. Anyone reading the numbers
above should conclude exactly what §8 concludes: only the GPU's throughput can
repay the work a batch is forced to do.

### 6.3 Per-node cost and flattening cost

A 16 383-node balanced tree that is guaranteed to execute every node (a random
tree crashes early, so "nodes in the tree" overstates the work done):

| evaluator | cost (3 runs, one core) |
|---|---|
| `evalTree` (interpreter) | 12.5 – 14.2 ns/node |
| `evalFlat` (flattened, in-process) | 9.7 – 10.9 ns/node |

So the flattened representation is only ~1.2× faster per node on one core: its
value is not CPU speed, it is being *executable by a kernel*.

| step | cost |
|---|---|
| `flattenTree` | 80 – 275 ns per instruction (varies with cache/GC pressure) |
| `encodeBatch` (wire) | ~0.1 s for the 9.4 M-instruction `median` population (≈ 90 MB) |

Flattening costs 7–30× one evaluation of the same node, so it only pays off
across many cases — at 100 cases it is ≈ 8 % of the batched evaluation, at 2
cases (one steady-state step) it would be a pure loss.

### 6.4 The external runner

`hotgp-perf gpu` sends a small batch through `gpu/gp_eval_cpu` and requires
identical fitnesses to the in-process reference. It does, on every problem
(`same fitnesses` in all rows), including problems where only part of the
population is eligible — the fallback path is exercised in the same run.

Per-batch overhead, 8 trees × 40 cases, `median` (≈ 1.5 M instructions):

| path | time |
|---|---|
| external runner (spawn + write + read + eval) | 157 ms |
| in-process reference | 146 ms |

Everything above the evaluation is ~10 ms; the rest is 320 full-program
evaluations, which is exactly the §6.2 effect again (a batch cannot skip cases).

---

## 7. Would a GPU win? A roofline for the `median` initial population

No GPU is available in this environment (§9), so this is arithmetic from the
measured sizes, with every assumption stated. Batch: 1000 programs,
9.43 M instructions, 100 cases ⇒ **943 M node-executions**, request ≈ **90 MB**
(8 B/instruction + 12 B/constant), response 1.6 MB.

| quantity | assumption | estimate |
|---|---|---|
| GPU throughput | ~3500 shader lanes × 1.7 GHz ≈ 6×10¹² lane-cycles/s; 2 cycles per node (stack-machine step, no divergence on the common ops) | 3×10¹² nodes/s |
| kernel time | 943 M / 3×10¹² | **≈ 0.3 ms** (1.6 ms at a pessimistic 10 cycles/node) |
| PCIe 3.0 x16 transfer | 90 MB at 12 GB/s | **≈ 7.5 ms** |
| PCIe 4.0 x16 transfer | 90 MB at 25 GB/s | ≈ 3.6 ms |
| total | transfer-bound | **≈ 4–10 ms** |

Against the measured 3.73 s serial score for the same population, that is a
**400–900×** reduction for the initial population, and — unlike the CPU batch —
it is not a loss even though all 100 cases are evaluated. The estimate is
deliberately unflattering: even at 4× the pessimistic kernel time and PCIe 3.0,
the batch stays under 15 ms (~250×).

The interesting part is *where* the time goes: **the batch is transfer-bound,
not compute-bound**. 90 MB of instruction streams cross PCIe to do 943 M nodes
of work; the GPU can execute them in a fraction of the time it takes to receive
them. That single fact drives every recommendation in §8.

---

## 8. Where the GPU can and cannot help HOTGP

**Level 0 — initial population (implemented).** One transfer per run, ~250–900×
on the scoring of `initPop` for the scalar benchmarks. Risk is low: the trees,
the RNG stream and the resulting population are identical to the serial path
(asserted in `test/GpuSpec.hs`). This is what `--gpu` selects.

**Level 1 — per-step batching.** Batch the ≤ 2 children of a step (2 programs ×
100 cases ≈ 150 KB, 1.9 M nodes). Kernel work would be ~0.6 µs; the transfer is
~12 µs. But the current backend pays a **process spawn (~5 ms) per batch**, and
150 000 steps × 5 ms is 12 minutes — fatal. Making this work needs FFI with a
persistent device context (allocate once, reuse buffers), after which a step's
scoring drops from ~10 ms to tens of microseconds; the 150 000 transfers then add
up to ~22 GB ≈ 1 s at 25 GB/s. The transfer is not the limit.

The limit is the rest of the step: **generating** two depth-15 children costs
~7 ms by itself here (3.6 ms/tree, measured on the initial population), against
~10 ms of evaluation for `median`. So even infinitely fast scoring would only
halve a run: an Amdahl ceiling of ~2× for Level 1. That, not the transfer, is
why Level 2 matters.

**Level 2 — keep the population on the device.** The real fix, and what Beagle
does: programs are already flat instruction arrays, so generation, crossover,
mutation, scoring and selection could all run device-side, with no per-step
transfer at all. That removes the 22 GB of traffic and makes the kernel the only
cost (≈ 35 ms of kernel time for a whole 300 000-evaluation run at the
throughput above, versus ~19 minutes of evaluation here). It is a rewrite of the engine, not
an optimisation of it, and it needs a device-side RNG and a device-side
population store. Worth doing only with a GPU to develop on.

**CPU-side alternatives worth more than a GPU for the other half of the
benchmarks.** For list/string programs the GPU is out (no allocator), but two
cheap CPU wins exist: (a) score the ≤ 2 children of a step on two cores — they
are independent, and `St` is pure, so this is a `forkIO`/`par` away (modulo
keeping the RNG order deterministic); (b) evaluate one program over 4–8 cases at
a time with SIMD — attractive in principle, but `if` makes control flow
data-dependent and crashes are per-case, so divergence has to be handled with
masks. Both are smaller projects than Level 2 and apply to *all* benchmarks,
not just the scalar ones.

**Things a GPU does not help here.** Test-set evaluation of the final best
individual (once per run), metric aggregation (~100 floats), population sorting
(1000 elements, `SortedList` already cheap), checkpointing (dominated by disk).
None of these is a meaningful fraction of a run.

---

## 9. Limitations / what was not verified

* **No GPU and no CUDA toolkit in this environment** (`nvidia-smi`/`nvcc`
  absent). `gpu/gp_eval.cu` has never been compiled or run here; only its C++
  twin (`gp_eval_cpu`, same kernel header, same wire format) was built and
  tested. The launch code is ~40 lines of `cudaMalloc`/`cudaMemcpy`/`<<<>>>`,
  but it is **unverified** — the first thing to do on a CUDA machine is
  `make -C gpu && ./gpu/verify_parity.sh` with the CUDA binary swapped in, and
  then compare fitnesses on a real benchmark.
* The §7 numbers are a projection, not a measurement. They are labelled as such
  on purpose: no speedup claim is made for hardware that was not available.
* The scalar subset excludes lists, strings, pairs and lambdas; for the
  benchmarks built on those, only 0.0–0.1 % of nodes are eligible (§6.1).
* The kernel's value stack is 32 entries (`HGP_MAX_STACK`), matching
  `Grammar.Flat.maxStackLimit`. A depth-15 tree needs at most 16; a degenerate
  spine deeper than 31 is rejected (and scored by the interpreter).
* Ints are 64-bit on the device (`Int64`), matching Haskell's `Int` on this
  platform. A 32-bit `Int` build would silently disagree; the tag/payload layout
  assumes 64-bit payloads.
* The batch path evaluates every case, while the serial path short-circuits on
  the first crash. Fitness is identical either way; *work* is not (§6.2).

---

## 10. Building and running

```sh
# Everything Haskell, including the test suite:
cabal build all
cabal test

# The GPU-free half of the GPU path: build the kernel as C++ and check parity.
make -C gpu cpu
./gpu/verify_parity.sh

# On a machine with CUDA:
make -C gpu            # builds gp_eval_cpu and gp_eval
HOTGP_GPU_RUNNER=./gpu/gp_eval cabal run hotgp-exe -- median 5 --gpu

# Batch the initial population on the in-process reference instead (no CUDA):
cabal run hotgp-exe -- median 5 --gpu-cpu

# Coverage / cost report behind §6:
cabal bench hotgp-perf --benchmark-options='gpu'
```

`--gpu` only ever touches the **initial population**; the steady-state loop is
unchanged, and a run resumed from a checkpoint never scores anything in a batch
(the checkpoint already carries scored individuals).

---

## 11. Files

Added:

* `src/Grammar/Flat.hs` — flattener, scalar subset, reference evaluator
* `src/Benchmark/Gpu.hs` — batch scoring, backends, interpreter fallback, `BatchScorer`
* `src/Benchmark/Gpu/Protocol.hs` — wire format
* `cbits/gp_flat_kernel.h` — kernel (CUDA and C++ from one source)
* `gpu/gp_eval.cu`, `gpu/gp_eval_cpu.cpp`, `gpu/Makefile`, `gpu/verify_parity.sh`
* `test/GpuSpec.hs` — differential and integration tests
* `GPU.md` — this document

Modified:

* `src/Evolution/Run.hs` — `runAndLogWith`, `initPopBatched`, `serialScorer`
* `src/Benchmark/BenchmarkToConfig.hs` — `outputsFitness` extracted so the serial
  and batched paths share one aggregation
* `src/Benchmark/Run.hs`, `src/Benchmark/Problems.hs`, `app/Main.hs` — `--gpu` /
  `--gpu-cpu` plumbing and batch statistics
* `bench/Perf.hs` — `gpu` mode (coverage, costs, runner check, per-node benchmark)
* `hotgp.cabal`, `package.yaml` — new modules, `bytestring`/`vector` for the
  benchmark, extra source files
