# gpu/ — the batch evaluators

Two programs, one kernel. Both read a batch request written by
`Benchmark.Gpu.Protocol` and write a response the Haskell side decodes; they
differ only in where `hgp_eval_case` runs.

| binary | built with | runs on |
|---|---|---|
| `gp_eval_cpu` | `g++` | the CPU; a GPU-free implementation of the same kernel, used for tests and as an `ExternalRunner` |
| `gp_eval` | `nvcc` | the GPU: one block per program, one thread per training case |

The kernel source is shared: `../cbits/gp_flat_kernel.h` is valid CUDA and valid
C++, so the CPU build is a faithful twin of the device code (this is how the GPU
path is verified on machines without a GPU).

```sh
make            # both (needs the CUDA toolkit for gp_eval)
make cpu        # just gp_eval_cpu (needs only g++)
make verify     # build the CPU twin and run the Haskell parity test
make NVCC_ARCH=-arch=sm_75   # target a specific GPU instead of -arch=native
```

Do not add `--use_fast_math`: it changes float division, `sqrt` and NaN
behaviour and would silently break parity with the interpreter.

See [`../GPU.md`](../GPU.md) for the design, the semantics that the kernel has
to preserve, the measurements and the limitations.
