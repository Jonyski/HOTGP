/*
 * gp_eval_cpu.cpp - runs a HOTGP batch on the CPU with the *same* kernel code
 * that the CUDA build runs on the device.
 *
 * Why this exists
 * ---------------
 * The kernel logic lives in cbits/gp_flat_kernel.h, which compiles as ordinary
 * C++ as well as CUDA. This program parses a batch, calls hgp_eval_case for
 * every (program, case) pair and writes the response - the exact contract
 * `gp_eval` (gp_eval.cu) fulfils on a GPU. It therefore
 *
 *  - lets the kernel and its wire protocol be tested on a machine with no GPU
 *    (test/GpuSpec.hs runs this binary when it is available), and
 *  - is a drop-in `ExternalRunner` for Benchmark.Gpu when no GPU is around.
 *
 * It is *not* a performance experiment: the point is bit-exact agreement with
 * Grammar.Flat.evalFlat, and the CUDA kernel differs only in the loop being
 * distributed over blocks and threads.
 *
 * Usage:  gp_eval_cpu <request.hgb> <response.hgx>
 */
#include <stdint.h>
#include <stdio.h>

#include <chrono>
#include <string>
#include <vector>

#include "gp_batch_io.h"
#include "gp_flat_kernel.h"

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <request.hgb> <response.hgx>\n", argv[0]);
    return 2;
  }

  HGPBatch batch;
  std::string err;
  if (!hgp_read_batch(argv[1], batch, err)) {
    fprintf(stderr, "gp_eval_cpu: %s\n", err.c_str());
    return 1;
  }

  auto t0 = std::chrono::steady_clock::now();

  std::vector<HGPOut> results((size_t)batch.nProgs * batch.nCases);
  for (uint32_t p = 0; p < batch.nProgs; ++p) {
    const HGPInstr *code = batch.code.data() + batch.codeOff[p];
    const uint32_t nInstr = batch.codeOff[p + 1] - batch.codeOff[p];
    const HGPVal *consts = batch.consts.data() + batch.constOff[p];
    const uint32_t nConst = batch.constOff[p + 1] - batch.constOff[p];

    for (uint32_t c = 0; c < batch.nCases; ++c) {
      const HGPVal *args = batch.args.data() + (size_t)c * batch.nArgs;
      HGPVal value;
      const bool ok = hgp_eval_case(code, nInstr, consts, nConst, args, batch.nArgs, &value);
      HGPOut &out = results[(size_t)p * batch.nCases + c];
      out.ok = ok ? 1u : 0u;
      out.tag = ok ? value.tag : 0u;
      out.bits = ok ? value.bits : 0ull;
    }
  }

  auto t1 = std::chrono::steady_clock::now();
  const double ms = std::chrono::duration<double, std::milli>(t1 - t0).count();

  if (!hgp_write_results(argv[2], results, batch.nProgs, batch.nCases)) {
    fprintf(stderr, "gp_eval_cpu: cannot write %s\n", argv[2]);
    return 1;
  }

  fprintf(stderr, "gp_eval_cpu: %u programs x %u cases = %llu evaluations in %.3f ms\n",
          batch.nProgs, batch.nCases,
          (unsigned long long)batch.nProgs * batch.nCases * 1ull, ms);
  return 0;
}
