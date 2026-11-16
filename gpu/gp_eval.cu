/*
 * gp_eval.cu - CUDA runner for a HOTGP fitness batch.
 *
 * Mapping (the one described in the Beagle paper)
 * ------------------------------------------------
 *   grid.x  = program (organism)  -> one CUDA block per program
 *   thread  = training case       -> one CUDA thread per fitness case
 *
 * A block therefore executes one candidate program on all of its training
 * cases in parallel, and blocks are independent of each other. That is exactly
 * the structure of HOTGP's fitness function - each tree is run on every
 * training case and the metric is applied to the results - so the parallelism
 * is embarrassingly wide: popSize x trainCases independent evaluations.
 *
 * What stays on the CPU
 * ---------------------
 * Only the evaluation. The metric (absolute error, boolean mismatch, ...) and
 * the aggregation - including the "one crash poisons the score" rule and the
 * order of floating-point additions - stay in Haskell
 * (Benchmark.BenchmarkToConfig.outputsFitness), so the GPU produces raw
 * per-case values and nothing else. That keeps the two paths trivially
 * comparable and lets a benchmark use any `Lit -> Lit -> a` metric without
 * touching the kernel.
 *
 * Memory layout
 * -------------
 * Programs have different lengths, so instructions and constants are
 * concatenated into two arrays with per-program offsets (codeOff, constOff).
 * Every case's arguments live in one flat array indexed by case. The whole
 * batch is three host->device transfers plus one device->host transfer.
 *
 * Build:  make            (see Makefile)
 * Run:    ./gp_eval <request.hgb> <response.hgx>
 *
 * Do not add --use_fast_math: it would change float division, sqrt and NaN
 * behaviour and break parity with the interpreter.
 */
#include <cuda_runtime.h>

#include <cstdio>
#include <string>
#include <vector>

#include "gp_batch_io.h"
#include "gp_flat_kernel.h"

/* Cases per block is capped because a block has at most 1024 threads. Current
 * benchmark datasets have at most 250 training cases, so in practice
 * blockDim.x == nCases and each block is exactly one organism's case set. If a
 * dataset grows past the cap, grid.y tiles it. */
#define HGP_MAX_THREADS 1024u

__global__ void hgp_batch_kernel(const HGPInstr *code, const uint32_t *codeOff,
                                 const HGPVal *consts, const uint32_t *constOff,
                                 const HGPVal *args, uint32_t nCases, uint32_t nArgs,
                                 HGPOut *out) {
  const uint32_t p = blockIdx.x;
  const uint32_t c = blockIdx.y * blockDim.x + threadIdx.x;
  if (c >= nCases) return;

  HGPVal value;
  const bool ok = hgp_eval_case(code + codeOff[p], codeOff[p + 1] - codeOff[p],
                                consts + constOff[p], constOff[p + 1] - constOff[p],
                                args + (size_t)c * nArgs, nArgs, &value);

  HGPOut r;
  r.ok = ok ? 1u : 0u;
  r.tag = ok ? value.tag : 0u;
  r.bits = ok ? value.bits : 0ull;
  out[(size_t)p * nCases + c] = r;
}

#define HGP_CHECK(call)                                                          \
  do {                                                                           \
    cudaError_t e_ = (call);                                                     \
    if (e_ != cudaSuccess) {                                                     \
      fprintf(stderr, "gp_eval: %s failed: %s\n", #call, cudaGetErrorString(e_)); \
      return 1;                                                                  \
    }                                                                            \
  } while (0)

/* Allocates a device buffer, copies `host` into it and returns the pointer
 * (nullptr for an empty vector, which cudaMemcpy would reject). */
template <typename T>
static T *upload(const std::vector<T> &host) {
  if (host.empty()) return nullptr;
  T *dev = nullptr;
  cudaMalloc((void **)&dev, host.size() * sizeof(T));
  cudaMemcpy(dev, host.data(), host.size() * sizeof(T), cudaMemcpyHostToDevice);
  return dev;
}

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <request.hgb> <response.hgx>\n", argv[0]);
    return 2;
  }

  HGPBatch batch;
  std::string err;
  if (!hgp_read_batch(argv[1], batch, err)) {
    fprintf(stderr, "gp_eval: %s\n", err.c_str());
    return 1;
  }
  if (batch.nProgs == 0 || batch.nCases == 0) {
    fprintf(stderr, "gp_eval: empty batch (%u programs, %u cases)\n", batch.nProgs, batch.nCases);
    return 0;
  }

  /* One block per program; each block owns up to HGP_MAX_THREADS cases. */
  const uint32_t block = batch.nCases < HGP_MAX_THREADS ? batch.nCases : HGP_MAX_THREADS;
  const dim3 grid(batch.nProgs, (batch.nCases + block - 1) / block, 1);
  const dim3 threads(block, 1, 1);

  HGPInstr *dCode = upload(batch.code);
  uint32_t *dCodeOff = upload(batch.codeOff);
  HGPVal *dConsts = upload(batch.consts);
  uint32_t *dConstOff = upload(batch.constOff);
  HGPVal *dArgs = upload(batch.args);

  HGPOut *dOut = nullptr;
  const size_t nOut = (size_t)batch.nProgs * batch.nCases;
  HGP_CHECK(cudaMalloc((void **)&dOut, nOut * sizeof(HGPOut)));

  cudaEvent_t start, stop;
  HGP_CHECK(cudaEventCreate(&start));
  HGP_CHECK(cudaEventCreate(&stop));
  HGP_CHECK(cudaEventRecord(start));

  hgp_batch_kernel<<<grid, threads>>>(dCode, dCodeOff, dConsts, dConstOff, dArgs,
                                      batch.nCases, batch.nArgs, dOut);
  HGP_CHECK(cudaGetLastError());

  HGP_CHECK(cudaEventRecord(stop));
  HGP_CHECK(cudaEventSynchronize(stop));
  float kernelMs = 0.0f;
  HGP_CHECK(cudaEventElapsedTime(&kernelMs, start, stop));

  std::vector<HGPOut> results(nOut);
  HGP_CHECK(cudaMemcpy(results.data(), dOut, nOut * sizeof(HGPOut), cudaMemcpyDeviceToHost));

  cudaFree(dCode);
  cudaFree(dCodeOff);
  cudaFree(dConsts);
  cudaFree(dConstOff);
  cudaFree(dArgs);
  cudaFree(dOut);
  cudaEventDestroy(start);
  cudaEventDestroy(stop);

  if (!hgp_write_results(argv[2], results, batch.nProgs, batch.nCases)) {
    fprintf(stderr, "gp_eval: cannot write %s\n", argv[2]);
    return 1;
  }

  fprintf(stderr, "gp_eval: %u programs x %u cases = %llu evaluations, kernel %.3f ms\n",
          batch.nProgs, batch.nCases, (unsigned long long)nOut, kernelMs);
  return 0;
}
