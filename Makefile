SLANG_VERSION ?= 2026.19
SLANG_PATH ?= .deps/slang-$(SLANG_VERSION)
SLANGC ?= $(SLANG_PATH)/bin/slangc
# Debug information keeps the statements of the source, which Slang folds into expressions otherwise
SLANGFLAGS = -line-directive-mode none -g2
ACTIONLINT_VERSION ?= 1.7.7
ACTIONLINT ?= .deps/actionlint
SOURCE = src/pathtracer.slang
NVCC ?= nvcc
FLEX_CUDA_PT ?= ../flex-cuda-pt
# Golden sources, the code the shared one replaces
REFERENCE ?= $(FLEX_CUDA_PT)/src/shaders
FLEXLIGHT ?= ../FlexLight
WGSL_REFERENCE ?= $(FLEXLIGHT)/src/flexlight/webgpu/shaders/pathtracer-compute.wgsl

all: build/cuda/pathtracer.cuh build/cuda/slang-cuda-prelude.h \
	build/wgsl/pathtracer.wgsl build/cuda/pathtracer.slang-module

# The prelude is included next to the header instead of from the Slang installation, its Matrix template, which the
# generated code takes for FlexLight's mat3x3, renamed SlangMatrix across the header so that it leaves the name to the
# consumer's
build/cuda/pathtracer.cuh: $(SOURCE) $(SLANGC)
	mkdir -p build/cuda
	$(SLANGC) $(SLANGFLAGS) $< -target cuda -o $@
	sed -i 's|^#include ".*/slang-cuda-prelude.h"|#pragma once\n#define Matrix SlangMatrix\n#include "slang-cuda-prelude.h"|' $@
	echo '#undef Matrix' >> $@

build/cuda/slang-cuda-prelude.h: $(SLANGC)
	mkdir -p build/cuda
	cp $(SLANG_PATH)/include/slang-cuda-prelude.h $@

build/wgsl/pathtracer.wgsl: $(SOURCE) $(SLANGC)
	mkdir -p build/wgsl
	$(SLANGC) $(SLANGFLAGS) $< -target wgsl -o $@

# The module flex-cuda-pt's Vulkan renderer imports, loadable by this Slang version alone, vendored with the CUDA header.
# It embeds the source's path, as given here, and debug information its absolute one, which it leaves out.
build/cuda/pathtracer.slang-module: $(SOURCE) $(SLANGC)
	mkdir -p build/cuda
	$(SLANGC) $< -o $@

build/cpp/pathtracer.cpp: $(SOURCE) $(SLANGC)
	mkdir -p build/cpp
	$(SLANGC) $(SLANGFLAGS) $< -target cpp -o $@

$(SLANGC):
	mkdir -p $(SLANG_PATH)
	curl -sSfL https://github.com/shader-slang/slang/releases/download/v$(SLANG_VERSION)/slang-$(SLANG_VERSION)-linux-x86_64.tar.gz \
		| tar -xz -C $(SLANG_PATH)

build/parity-cpu: tests/parity.cpp build/cpp/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -Ibuild/cpp $< -o $@

build/albedo-cpu: tests/albedo.cpp build/cpp/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -Ibuild/cpp $< -o $@

# With flex-cuda-pt's structs the header leaves to it
build/parity-cuda: tests/parity.cpp build/cuda/pathtracer.cuh build/cuda/slang-cuda-prelude.h $(REFERENCE)/renderer.h
	$(NVCC) -std=c++20 -O2 -x cu -Ibuild/cuda -I$(REFERENCE) $< -o $@

$(ACTIONLINT):
	mkdir -p .deps
	curl -sSfL https://github.com/rhysd/actionlint/releases/download/v$(ACTIONLINT_VERSION)/actionlint_$(ACTIONLINT_VERSION)_linux_amd64.tar.gz \
		| tar -xz -C .deps actionlint

.PHONY: all lint test test-cpu test-wgsl test-cuda test-vulkan golden golden-wgsl deploy-local clean
lint: $(ACTIONLINT)
	$(ACTIONLINT)

test: test-cpu test-wgsl test-vulkan

# What only FlexLight had against its goldens, but what draws random numbers
test-cpu: build/parity-cpu build/albedo-cpu
	$< < tests/golden-cuda.txt > build/cpu.txt
	build/albedo-cpu
	node tests/compare.mjs tests/golden-cuda.txt build/cpu.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/cpu.txt 58

test-wgsl: build/wgsl/pathtracer.wgsl
	node tests/wgsl.mjs $< < tests/golden-wgsl.txt > build/wgsl.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/wgsl.txt

test-cuda: build/parity-cuda  # On the GPU
	$< < tests/golden-cuda.txt > build/cuda.txt
	node tests/compare.mjs tests/golden-cuda.txt build/cuda.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/cuda.txt 58

test-vulkan: tests/vulkan.slang build/cuda/pathtracer.slang-module  # Compile only
	$(SLANGC) -Ibuild/cuda $< -target spirv -o build/vulkan.spv

golden: tests/reference.cpp tests/shim/*.h $(REFERENCE)/renderer.cu $(REFERENCE)/renderer.h
	mkdir -p build
	$(CXX) -std=c++20 -O2 -Itests/shim -I$(REFERENCE) $< -o build/reference
	build/reference > tests/golden-cuda.txt

# On the grid of the CUDA goldens
golden-wgsl: tests/wgsl.mjs tests/golden-cuda.txt $(WGSL_REFERENCE)
	node tests/wgsl.mjs $(WGSL_REFERENCE) --flexlight < tests/golden-cuda.txt > tests/golden-wgsl.txt

# Into sibling checkouts, as CI does into the consumer repos
deploy-local: all
	mkdir -p $(FLEX_CUDA_PT)/src/shaders/flexkernels $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels
	cp build/cuda/* $(FLEX_CUDA_PT)/src/shaders/flexkernels
	cp build/wgsl/* $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels
	git rev-parse HEAD | tee $(FLEX_CUDA_PT)/src/shaders/flexkernels/VERSION \
		> $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels/VERSION

clean:
	rm -rf build
