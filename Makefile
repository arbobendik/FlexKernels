SLANG_VERSION ?= 2026.19
SLANG_PATH ?= .deps/slang
SLANGC ?= $(SLANG_PATH)/bin/slangc
SLANGFLAGS = -line-directive-mode none
MODULES = src/math.slang src/random.slang src/bsdf.slang
NVCC ?= nvcc
HIPCC ?= hipcc
FLEX_CUDA_PT ?= ../flex-cuda-pt
# Golden source, the BSDF the shared one replaces
REFERENCE ?= $(FLEX_CUDA_PT)/src/shaders
FLEXLIGHT ?= ../FlexLight

all: build/cuda/bsdf.cuh build/cuda/slang-cuda-prelude.h build/hip/bsdf.cuh build/hip/slang-cuda-prelude.h \
	build/wgsl/bsdf.wgsl

# The prelude is included next to the header instead of from the Slang installation, its Matrix template, which the
# generated code doesn't use, renamed so that it leaves the name to the consumer's
build/cuda/bsdf.cuh: $(MODULES) $(SLANGC)
	mkdir -p build/cuda
	$(SLANGC) $(SLANGFLAGS) src/bsdf.slang -target cuda -o $@
	sed -i 's|^#include ".*/slang-cuda-prelude.h"|#pragma once\n#define Matrix SlangMatrix\n#include "slang-cuda-prelude.h"\n#undef Matrix|' $@

build/cuda/slang-cuda-prelude.h: $(SLANGC)
	mkdir -p build/cuda
	cp $(SLANG_PATH)/include/slang-cuda-prelude.h $@

# The same header for HIP, with the part of the prelude it uses
build/hip/bsdf.cuh: build/cuda/bsdf.cuh
	mkdir -p build/hip
	cp $< $@

build/hip/slang-cuda-prelude.h: src/hip-prelude.h
	mkdir -p build/hip
	cp $< $@

build/wgsl/bsdf.wgsl: $(MODULES) $(SLANGC)
	mkdir -p build/wgsl
	$(SLANGC) $(SLANGFLAGS) src/bsdf.slang -target wgsl -o $@

build/cpp/bsdf.cpp: $(MODULES) $(SLANGC)
	mkdir -p build/cpp
	$(SLANGC) $(SLANGFLAGS) src/bsdf.slang -target cpp -o $@

$(SLANGC):
	mkdir -p $(SLANG_PATH)
	curl -sSfL https://github.com/shader-slang/slang/releases/download/v$(SLANG_VERSION)/slang-$(SLANG_VERSION)-linux-x86_64.tar.gz \
		| tar -xz -C $(SLANG_PATH)

build/parity-cpu: tests/parity.cpp build/cpp/bsdf.cpp
	$(CXX) -std=c++20 -O2 -Ibuild/cpp $< -o $@

build/parity-cuda: tests/parity.cpp build/cuda/bsdf.cuh build/cuda/slang-cuda-prelude.h
	$(NVCC) -std=c++20 -O2 -x cu -Ibuild/cuda $< -o $@

.PHONY: all test test-cpu test-wgsl test-cuda test-hip golden deploy-local clean
test: test-cpu test-wgsl

test-cpu: build/parity-cpu
	$< < tests/golden.txt > build/cpu.txt
	node tests/compare.mjs tests/golden.txt build/cpu.txt

test-wgsl: build/wgsl/bsdf.wgsl
	node tests/wgsl.mjs $< < tests/golden.txt > build/wgsl.txt
	node tests/compare.mjs tests/golden.txt build/wgsl.txt

test-cuda: build/parity-cuda  # On the GPU
	$< < tests/golden.txt > build/cuda.txt
	node tests/compare.mjs tests/golden.txt build/cuda.txt

test-hip: build/hip/bsdf.cuh build/hip/slang-cuda-prelude.h  # Compile only
	$(HIPCC) -std=c++20 --offload-arch=gfx1100 -x hip -c $< -o build/hip/bsdf.o

golden: tests/reference.cpp tests/shim/*.h $(REFERENCE)/renderer.cu $(REFERENCE)/renderer.h
	mkdir -p build
	$(CXX) -std=c++20 -O2 -Itests/shim -I$(REFERENCE) $< -o build/reference
	build/reference > tests/golden.txt

# Into sibling checkouts, as CI does into the consumer repos
deploy-local: all
	mkdir -p $(FLEX_CUDA_PT)/src/shaders/flexkernels $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels
	cp build/cuda/* $(FLEX_CUDA_PT)/src/shaders/flexkernels
	cp build/wgsl/* $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels
	git rev-parse HEAD | tee $(FLEX_CUDA_PT)/src/shaders/flexkernels/VERSION \
		> $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels/VERSION

clean:
	rm -rf build
