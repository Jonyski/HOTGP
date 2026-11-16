/*
 * gp_batch_io.h - host-side reader/writer for the HOTGP batch format.
 *
 * Shared by the CUDA runner (gp_eval.cu) and the CPU simulator that verifies
 * it (gp_eval_cpu.cpp), so the two cannot disagree about the file format.
 * The format is documented in src/Benchmark/Gpu/Protocol.hs; the short version:
 *
 *   request:  "HGB1" u32 v=1 nPrograms nCases nArgs
 *             nPrograms x { nInstr nConst maxStack
 *                           nInstr x {op, arg}
 *                           nConst x {tag, bits} }
 *             nCases x nArgs x {tag, bits}
 *   response: "HGX1" u32 v=1 nPrograms nCases
 *             nPrograms*nCases x {ok, tag, bits}
 *
 * Everything is read into memory at once: a full-population batch is a few
 * hundred kilobytes, and streaming would only add failure modes.
 *
 * Little-endian is assumed (x86-64, ARM64 and every GPU host today). If that
 * ever stops being true, this file is the only place to fix.
 */
#ifndef HGP_BATCH_IO_H
#define HGP_BATCH_IO_H

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <string>
#include <vector>

#include "gp_flat_kernel.h"

#define HGP_REQ_MAGIC 0x31424748u /* "HGB1" */
#define HGP_RES_MAGIC 0x31584748u /* "HGX1" */
#define HGP_VERSION 1u

/* A parsed request, laid out the way the kernel wants it: each program's
 * instructions and constants are concatenated, with an offset table, so the
 * device needs one transfer per array instead of one per program. */
struct HGPBatch {
  uint32_t nProgs = 0;
  uint32_t nCases = 0;
  uint32_t nArgs = 0;

  std::vector<HGPInstr> code;
  std::vector<uint32_t> codeOff; /* nProgs + 1 entries */

  std::vector<HGPVal> consts;
  std::vector<uint32_t> constOff; /* nProgs + 1 entries */

  std::vector<uint32_t> maxStack; /* per program */

  std::vector<HGPVal> args; /* nCases * nArgs values */
};

/* Reads a whole file into `out`. Returns false on any I/O error. */
static inline bool hgp_read_file(const char *path, std::vector<unsigned char> &out) {
  FILE *f = fopen(path, "rb");
  if (!f) return false;
  if (fseek(f, 0, SEEK_END) != 0) {
    fclose(f);
    return false;
  }
  long size = ftell(f);
  if (size < 0) {
    fclose(f);
    return false;
  }
  rewind(f);
  out.resize((size_t)size);
  size_t got = size > 0 ? fread(out.data(), 1, (size_t)size, f) : 0;
  fclose(f);
  return got == (size_t)size;
}

/* Bounds-checked little-endian cursor over the request bytes. Every read
 * either succeeds or is reported, so a truncated or hostile file produces an
 * error message instead of a segfault. */
struct HGPCursor {
  const unsigned char *data;
  size_t size;
  size_t off;
  bool ok;

  HGPCursor(const unsigned char *d, size_t n) : data(d), size(n), off(0), ok(true) {}

  bool need(size_t n) {
    if (!ok || off + n > size) {
      ok = false;
      return false;
    }
    return true;
  }

  uint32_t u32() {
    if (!need(4)) return 0;
    uint32_t v;
    memcpy(&v, data + off, 4);
    off += 4;
    return v;
  }

  uint64_t u64() {
    if (!need(8)) return 0;
    uint64_t v;
    memcpy(&v, data + off, 8);
    off += 8;
    return v;
  }

  /* tag + payload, as the wire format stores them. */
  HGPVal val() {
    HGPVal v;
    v.tag = u32();
    v.bits = u64();
    v.pad = 0;
    return v;
  }
};

/* Parses a request file. `err` describes the failure when false is returned. */
static inline bool hgp_read_batch(const char *path, HGPBatch &batch, std::string &err) {
  std::vector<unsigned char> raw;
  if (!hgp_read_file(path, raw)) {
    err = std::string("cannot read ") + path;
    return false;
  }

  HGPCursor cur(raw.data(), raw.size());
  uint32_t magic = cur.u32();
  uint32_t version = cur.u32();
  batch.nProgs = cur.u32();
  batch.nCases = cur.u32();
  batch.nArgs = cur.u32();
  if (!cur.ok) {
    err = "truncated request header";
    return false;
  }
  if (magic != HGP_REQ_MAGIC) {
    err = "bad request magic";
    return false;
  }
  if (version != HGP_VERSION) {
    err = "unsupported request version";
    return false;
  }

  batch.codeOff.reserve(batch.nProgs + 1);
  batch.constOff.reserve(batch.nProgs + 1);
  batch.maxStack.reserve(batch.nProgs);
  batch.codeOff.push_back(0);
  batch.constOff.push_back(0);

  for (uint32_t p = 0; p < batch.nProgs; ++p) {
    uint32_t nInstr = cur.u32();
    uint32_t nConst = cur.u32();
    uint32_t maxStack = cur.u32();
    if (!cur.ok) {
      err = "truncated program header";
      return false;
    }
    if (maxStack > HGP_MAX_STACK) {
      err = "program needs a stack deeper than HGP_MAX_STACK";
      return false;
    }
    batch.maxStack.push_back(maxStack);
    for (uint32_t i = 0; i < nInstr; ++i) {
      HGPInstr ins;
      ins.op = cur.u32();
      ins.arg = cur.u32();
      batch.code.push_back(ins);
    }
    for (uint32_t c = 0; c < nConst; ++c) {
      batch.consts.push_back(cur.val());
    }
    if (!cur.ok) {
      err = "truncated program body";
      return false;
    }
    batch.codeOff.push_back((uint32_t)batch.code.size());
    batch.constOff.push_back((uint32_t)batch.consts.size());
  }

  batch.args.reserve((size_t)batch.nCases * batch.nArgs);
  for (uint32_t c = 0; c < batch.nCases; ++c) {
    for (uint32_t a = 0; a < batch.nArgs; ++a) {
      batch.args.push_back(cur.val());
    }
  }
  if (!cur.ok) {
    err = "truncated case data";
    return false;
  }
  return true;
}

/* Writes a response file. `results` holds nProgs * nCases records in
 * program-major order. */
static inline bool hgp_write_results(const char *path, const std::vector<HGPOut> &results,
                                     uint32_t nProgs, uint32_t nCases) {
  FILE *f = fopen(path, "wb");
  if (!f) return false;
  uint32_t header[4] = {HGP_RES_MAGIC, HGP_VERSION, nProgs, nCases};
  bool ok = fwrite(header, sizeof(uint32_t), 4, f) == 4;
  for (size_t i = 0; ok && i < results.size(); ++i) {
    /* Ok, tag and payload are written field by field so the record layout does
     * not depend on the compiler's struct padding. */
    uint32_t okField = results[i].ok;
    uint32_t tag = results[i].tag;
    uint64_t bits = results[i].bits;
    ok = ok && fwrite(&okField, sizeof(uint32_t), 1, f) == 1;
    ok = ok && fwrite(&tag, sizeof(uint32_t), 1, f) == 1;
    ok = ok && fwrite(&bits, sizeof(uint64_t), 1, f) == 1;
  }
  fclose(f);
  return ok;
}

#endif /* HGP_BATCH_IO_H */
