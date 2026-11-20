SLANG_VERSION ?= 2026.19
SLANG_PATH ?= .deps/slang-$(SLANG_VERSION)
SLANGC ?= $(SLANG_PATH)/bin/slangc
# -g2 keeps statements Slang would fold, warning 30081 (implicit conversion) fails the build
SLANGFLAGS = -line-directive-mode none -g2 -warnings-as-errors 30081
ACTIONLINT_VERSION ?= 1.7.7
ACTIONLINT ?= .deps/actionlint
SOURCE = src/pathtracer.slang src/walk.slang
NVCC ?= nvcc
FLEX_CUDA_PT ?= ../flex-cuda-pt
# Golden sources
REFERENCE ?= $(FLEX_CUDA_PT)/src/shaders
FLEXLIGHT ?= ../FlexLight
WGSL_REFERENCE ?= $(FLEXLIGHT)/src/flexlight/webgpu/shaders/pathtracer-compute.wgsl

all: build/cuda/pathtracer.cuh \
	build/wgsl/pathtracer.wgsl build/glsl/pathtracer.glsl build/cuda/pathtracer.slang-module \
	build/cuda-restir/pathtracer.cuh build/wgsl-restir/pathtracer.wgsl \
	build/cuda-restir/pathtracer.slang-module

# ReSTIR variants
build/cuda-restir/pathtracer.cuh build/wgsl-restir/pathtracer.wgsl: SLANGFLAGS += -DFK_RESTIR=1
build/cuda-restir/pathtracer.cuh: SLANGFLAGS += -DFK_FCPT_WALK=1 -DFK_RESTIR_PASSES=1
build/cuda-restir/pathtracer.slang-module: MODULEFLAGS = -DFK_RESTIR=1 -DFK_FCPT_WALK=1 -DFK_HAIR=1 \
	-DFK_TOON=1 -DFK_RESTIR_PASSES=1
build/cuda/pathtracer.cuh build/cuda-restir/pathtracer.cuh build/cpp/pathtracer.cpp build/cpp-restir/pathtracer.cpp \
		build/cpp-passes/pathtracer.cpp: SLANGFLAGS += -DFK_HAIR=1
build/cuda/pathtracer.slang-module: MODULEFLAGS = -DFK_HAIR=1
build/cuda-restir/pathtracer.cuh build/cpp/pathtracer.cpp build/cpp-restir/pathtracer.cpp \
		build/cpp-passes/pathtracer.cpp: SLANGFLAGS += -DFK_TOON=1
build/wgsl-restir/pathtracer.wgsl: SLANGFLAGS += -DFK_RESTIR_PASSES=1
build/restir-passes/pathtracer.slang-module: MODULEFLAGS = -DFK_RESTIR=1 -DFK_RESTIR_PASSES=1

# Prelude included by name, Matrix renamed SlangMatrix
build/cuda/pathtracer.cuh build/cuda-restir/pathtracer.cuh: $(SOURCE) $(SLANGC)
	mkdir -p $(@D)
	$(SLANGC) $(SLANGFLAGS) $< -target cuda -o $@
	sed -i 's|^#include ".*/slang-cuda-prelude.h"|#pragma once\n#define Matrix SlangMatrix\n#include "slang-cuda-prelude.h"|' $@
	sed -i 's|^__device__ BSDFLobes bsdfLobes(|__device__ __forceinline__ BSDFLobes bsdfLobes(|' $@
	sed -i -E 's/^__device__ (ToonShape toonShape)\(/__device__ __forceinline__ \1(/' $@
	sed -i -E 's/^__device__ (HalfTerms (sampled|reflected|refracted)Half)\(/__device__ __forceinline__ \1(/' $@
	sed -i -E 's/^__device__ (float3  (diffuse|refract|reflect|sheenVelvet|toon)BSDF)\(/__device__ __forceinline__ \1(/' $@
	sed -i -E 's/^__device__ (SampleBSDF [a-zA-Z]+Sample|float [a-zA-Z]+PDF)\(/__device__ __forceinline__ \1(/' $@
	sed -i -E 's/^__device__ (float3  BSDF|SampleBSDF sampleBSDF)\(/__device__ __forceinline__ \1(/' $@
	sed -i -E 's/^__device__ (float3  sampleHalfVector)\(/__device__ __forceinline__ \1(/' $@
	sed -i 's/^static __device__ __noinline__ /static __device__ /' $@
	sed -i -E 's/^static __device__ (TreeSample sampleLightTree_0|float3  lightBSDF_0|float3  skyLobes_0)\(/static __device__ __forceinline__ \1(/' $@
	case $@ in *-restir/*) sed -i 's/^__device__ float childShare(/__device__ __forceinline__ float childShare(/' $@;; esac
	echo '#undef Matrix' >> $@

build/wgsl/pathtracer.wgsl build/wgsl-restir/pathtracer.wgsl: $(SOURCE) $(SLANGC)
	mkdir -p $(@D)
	$(SLANGC) $(SLANGFLAGS) $< -target wgsl -o $@

# GLSL ES 3.00 without the version and layout lines and the entry point
build/glsl/pathtracer.glsl: src/glsl.slang $(SOURCE) $(SLANGC)
	mkdir -p build/glsl
	$(SLANGC) $(SLANGFLAGS) $< -entry main -stage fragment -target glsl -o $@
	sed -i -e '/^#version/d' -e '/^layout(row_major)/d' -e '/^layout(location = 0)$$/,/^}$$/d' $@

build/cuda/pathtracer.slang-module build/cuda-restir/pathtracer.slang-module \
		build/restir-passes/pathtracer.slang-module: $(SOURCE) $(SLANGC)
	mkdir -p $(@D)
	$(SLANGC) $< -warnings-as-errors 30081 $(MODULEFLAGS) -o $@

build/cpp/pathtracer.cpp: $(SOURCE) $(SLANGC)
	mkdir -p build/cpp
	$(SLANGC) $(SLANGFLAGS) $< -target cpp -o $@

$(SLANGC):
	mkdir -p $(SLANG_PATH)
	curl -sSfL https://github.com/shader-slang/slang/releases/download/v$(SLANG_VERSION)/slang-$(SLANG_VERSION)-linux-x86_64.tar.gz \
		| tar -xz -C $(SLANG_PATH)

# The CPU build without FK_TOON, against which a material without toon must stay bit-identical
build/cpp-untoon/pathtracer.cpp: $(SOURCE) $(SLANGC)
	mkdir -p build/cpp-untoon
	$(SLANGC) $(SLANGFLAGS) -DFK_HAIR=1 $< -target cpp -o $@

build/parity-untoon-cpu: tests/parity.cpp build/cpp-untoon/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -DFK_UNTOON=1 -Ibuild/cpp-untoon $< -o $@

build/parity-cpu: tests/parity.cpp build/cpp/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -Ibuild/cpp $< -o $@

build/albedo-cpu: tests/albedo.cpp build/cpp/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -Ibuild/cpp $< -o $@

build/dispersion-cpu: tests/dispersion.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/cpp-restir/pathtracer.cpp: $(SOURCE) $(SLANGC)
	mkdir -p build/cpp-restir
	$(SLANGC) $(SLANGFLAGS) -DFK_RESTIR=1 -DFK_FCPT_WALK=1 $< -target cpp -o $@

build/cpp-passes/pathtracer.cpp: $(SOURCE) $(SLANGC)
	mkdir -p build/cpp-passes
	$(SLANGC) $(SLANGFLAGS) -DFK_RESTIR=1 -DFK_FCPT_WALK=1 -DFK_RESTIR_PASSES=1 $< -target cpp -o $@

build/passes-cpu: tests/passes.cpp build/cpp-passes/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-passes $< -o $@

build/summing-cpu: tests/summing.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/walk-cpu: tests/walk.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/scatternee-cpu: tests/scatternee.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/flight-cpu: tests/flight.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/shadowmedia-cpu: tests/shadowmedia.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/media-cpu: tests/media.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/pathray-cpu: tests/pathray.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/layers-cpu: tests/layers.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/cones-cpu: tests/cones.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/coverage-cpu: tests/coverage.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -fdata-sections -Wl,--gc-sections -Ibuild/cpp-restir \
		-DGENERATED='"build/cpp-restir/pathtracer.cpp"' $< -o $@

build/parity-cuda: tests/parity.cpp build/cuda/pathtracer.cuh $(REFERENCE)/renderer.h
	$(NVCC) -std=c++20 -O2 -x cu -Ibuild/cuda -I$(SLANG_PATH)/include -I$(REFERENCE) $< -o $@

$(ACTIONLINT):
	mkdir -p .deps
	curl -sSfL https://github.com/rhysd/actionlint/releases/download/v$(ACTIONLINT_VERSION)/actionlint_$(ACTIONLINT_VERSION)_linux_amd64.tar.gz \
		| tar -xz -C .deps actionlint

.PHONY: all lint test test-cpu test-wgsl test-cuda test-vulkan golden-wgsl deploy-local clean
lint: $(ACTIONLINT)
	$(ACTIONLINT)

test: test-cpu test-wgsl test-vulkan

test-cpu: build/parity-cpu build/parity-untoon-cpu build/albedo-cpu build/coverage-cpu build/cones-cpu \
		build/layers-cpu build/pathray-cpu build/media-cpu build/shadowmedia-cpu \
		build/flight-cpu build/scatternee-cpu build/walk-cpu \
		build/summing-cpu build/passes-cpu build/dispersion-cpu
	$< < tests/golden-cuda.txt > build/cpu.txt
	build/parity-untoon-cpu < tests/golden-cuda.txt | cmp - build/cpu.txt
	build/albedo-cpu
	build/coverage-cpu
	build/cones-cpu
	build/layers-cpu
	build/pathray-cpu
	build/media-cpu
	build/shadowmedia-cpu
	build/flight-cpu
	build/scatternee-cpu
	build/walk-cpu
	build/summing-cpu
	build/passes-cpu
	build/dispersion-cpu
	node tests/compare.mjs tests/golden-cuda.txt build/cpu.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/cpu.txt 58

test-wgsl: build/wgsl/pathtracer.wgsl build/wgsl-restir/pathtracer.wgsl
	node tests/parse-wgsl.mjs $^
	node tests/wgsl.mjs $< < tests/golden-wgsl.txt > build/wgsl.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/wgsl.txt

test-cuda: build/parity-cuda
	$< < tests/golden-cuda.txt > build/cuda.txt
	node tests/compare.mjs tests/golden-cuda.txt build/cuda.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/cuda.txt 58

test-vulkan: tests/vulkan.slang build/cuda/pathtracer.slang-module build/cuda-restir/pathtracer.slang-module \
		build/restir-passes/pathtracer.slang-module  # Compile and validate only
	$(SLANGC) -Ibuild/cuda -warnings-as-errors 30081 $< -target spirv -o build/vulkan.spv
	spirv-val --target-env vulkan1.3 build/vulkan.spv
	$(SLANGC) -Ibuild/cuda-restir -DFK_RESTIR=1 -DFK_RESTIR_PASSES=1 -DFK_FCPT_WALK=1 -warnings-as-errors 30081 $< \
		-target spirv -o build/vulkan-restir.spv
	spirv-val --target-env vulkan1.3 build/vulkan-restir.spv
	$(SLANGC) -Ibuild/restir-passes -DFK_RESTIR=1 -DFK_RESTIR_PASSES=1 -warnings-as-errors 30081 $< -target spirv \
		-o build/vulkan-passes.spv
	spirv-val --target-env vulkan1.3 build/vulkan-passes.spv

golden-wgsl: tests/wgsl.mjs tests/golden-cuda.txt $(WGSL_REFERENCE)
	node tests/wgsl.mjs $(WGSL_REFERENCE) --flexlight < tests/golden-cuda.txt > tests/golden-wgsl.txt

deploy-local: all
	mkdir -p $(FLEX_CUDA_PT)/src/shaders/flexkernels $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels \
		$(FLEXLIGHT)/src/flexlight/webgl2/shaders/flexkernels
	cp build/cuda/* $(FLEX_CUDA_PT)/src/shaders/flexkernels
	cp build/wgsl/* $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels
	cp build/glsl/* $(FLEXLIGHT)/src/flexlight/webgl2/shaders/flexkernels
	git rev-parse HEAD | tee $(FLEX_CUDA_PT)/src/shaders/flexkernels/VERSION $(FLEXLIGHT)/src/flexlight/webgl2/shaders/flexkernels/VERSION \
		> $(FLEXLIGHT)/src/flexlight/webgpu/shaders/flexkernels/VERSION

clean:
	rm -rf build
