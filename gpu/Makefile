# Builds the HOTGP batch evaluators.
#
#   make            both: gp_eval_cpu (always) and gp_eval (needs CUDA)
#   make cpu        only the CPU simulator (no CUDA toolkit required)
#   make verify     builds the CPU simulator and runs the parity script
#   make clean
#
# The kernel itself lives in ../cbits/gp_flat_kernel.h, shared by both
# binaries. `-arch=native` targets the GPU of the build machine; override it
# (e.g. `make NVCC_ARCH=-arch=sm_75`) to target a different one or to build on
# a machine without a GPU. Never add --use_fast_math: it changes float
# division, sqrt and NaN behaviour and breaks parity with the interpreter.

CXX      ?= g++
NVCC     ?= nvcc
NVCC_ARCH ?= -arch=native
CXXFLAGS ?= -O2 -std=c++17 -Wall -Wextra
NVCCFLAGS ?= -O2 -std=c++17 $(NVCC_ARCH)

DEPS = gp_batch_io.h ../cbits/gp_flat_kernel.h

.PHONY: all cpu cuda verify clean

all: gp_eval_cpu gp_eval

cpu: gp_eval_cpu

cuda: gp_eval

gp_eval_cpu: gp_eval_cpu.cpp $(DEPS)
	$(CXX) $(CXXFLAGS) -I../cbits -o $@ gp_eval_cpu.cpp

gp_eval: gp_eval.cu $(DEPS)
	$(NVCC) $(NVCCFLAGS) -I../cbits -o $@ gp_eval.cu

verify: gp_eval_cpu
	./verify_parity.sh

clean:
	rm -f gp_eval_cpu gp_eval gp_verify_req.hgb gp_verify.res
