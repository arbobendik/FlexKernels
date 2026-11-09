SLANG_VERSION ?= 2026.19
SLANG_PATH ?= .deps/slang-$(SLANG_VERSION)
SLANGC ?= $(SLANG_PATH)/bin/slangc
# Debug information keeps the statements of the source, which Slang folds into expressions otherwise
# Implicit conversions that change a value's type, such as uints reaching float overloads, fail the build
SLANGFLAGS = -line-directive-mode none -g2 -warnings-as-errors 30081
ACTIONLINT_VERSION ?= 1.7.7
ACTIONLINT ?= .deps/actionlint
SOURCE = src/pathtracer.slang src/walk.slang
NVCC ?= nvcc
FLEX_CUDA_PT ?= ../flex-cuda-pt
# Golden sources, the code the shared one replaces
REFERENCE ?= $(FLEX_CUDA_PT)/src/shaders
FLEXLIGHT ?= ../FlexLight
WGSL_REFERENCE ?= $(FLEXLIGHT)/src/flexlight/webgpu/shaders/pathtracer-compute.wgsl

all: build/cuda/pathtracer.cuh build/cuda/slang-cuda-prelude.h \
	build/wgsl/pathtracer.wgsl build/glsl/pathtracer.glsl build/cuda/pathtracer.slang-module \
	build/cuda-restir/pathtracer.cuh build/cuda-restir/slang-cuda-prelude.h build/wgsl-restir/pathtracer.wgsl \
	build/cuda-restir/pathtracer.slang-module

# The ReSTIR variants, which ReSTIR's consumers take in place of the outputs above: walk.slang's declarations and its
# hooks bridged to the consumer's own functions, which the outputs above leave out, as they call nothing that is not
# defined and the module exports no name its importers declare themselves
build/cuda-restir/pathtracer.cuh build/wgsl-restir/pathtracer.wgsl: SLANGFLAGS += -DFK_RESTIR=1
# flex-cuda-pt's walk features' struct fields, which FlexLight's would carry unused
build/cuda-restir/pathtracer.cuh: SLANGFLAGS += -DFK_FCPT_WALK=1
build/cuda-restir/pathtracer.slang-module: MODULEFLAGS = -DFK_RESTIR=1 -DFK_FCPT_WALK=1
# FlexLight's takes the passes as well, flex-cuda-pt's the walk and shift alone, and the Vulkan test both
build/wgsl-restir/pathtracer.wgsl: SLANGFLAGS += -DFK_RESTIR_PASSES=1
build/restir-passes/pathtracer.slang-module: MODULEFLAGS = -DFK_RESTIR=1 -DFK_RESTIR_PASSES=1

# The prelude is included next to the header instead of from the Slang installation, its Matrix template, which the
# generated code takes for FlexLight's mat3x3, renamed SlangMatrix across the header so that it leaves the name to the
# consumer's
build/cuda/pathtracer.cuh build/cuda-restir/pathtracer.cuh: $(SOURCE) $(SLANGC)
	mkdir -p $(@D)
	$(SLANGC) $(SLANGFLAGS) $< -target cuda -o $@
	sed -i 's|^#include ".*/slang-cuda-prelude.h"|#pragma once\n#define Matrix SlangMatrix\n#include "slang-cuda-prelude.h"|' $@
	# bsdfLobes inlined, as nvcc inlines it into consumers' code without the translucent share's callers, which grow it
	# past nvcc's threshold: consumers specializing a material's constants fold them only through inlined code
	sed -i 's|^__device__ BSDFLobes bsdfLobes(|__device__ __forceinline__ BSDFLobes bsdfLobes(|' $@
	# connectBSDF likewise, which the sheen's branches grow past it where consumers specialize the sheen only after nvcc
	sed -i 's|^__device__ SampleBSDF connectBSDF(|__device__ __forceinline__ SampleBSDF connectBSDF(|' $@
	# The rest of the BSDF's path consumers inline, so that no lobe's code flips nvcc's choice
	sed -i -E 's/^__device__ (float3  lobeThroughput|float lobeDensity|float3  BSDF|SampleBSDF sampleBSDF|float3  neeBSDF|float3  sampleMaterialHalfVector)\(/__device__ __forceinline__ \1(/' $@
	echo '#undef Matrix' >> $@

build/cuda/slang-cuda-prelude.h build/cuda-restir/slang-cuda-prelude.h: $(SLANGC)
	mkdir -p $(@D)
	cp $(SLANG_PATH)/include/slang-cuda-prelude.h $@

build/wgsl/pathtracer.wgsl build/wgsl-restir/pathtracer.wgsl: $(SOURCE) $(SLANGC)
	mkdir -p $(@D)
	$(SLANGC) $(SLANGFLAGS) $< -target wgsl -o $@

# WebGL2's GLSL ES 3.00, without the version and layout lines, which FlexLight's shader leads with, or the entry point
build/glsl/pathtracer.glsl: src/glsl.slang $(SOURCE) $(SLANGC)
	mkdir -p build/glsl
	$(SLANGC) $(SLANGFLAGS) $< -entry main -stage fragment -target glsl -o $@
	sed -i -e '/^#version/d' -e '/^layout(row_major)/d' -e '/^layout(location = 0)$$/,/^}$$/d' $@

# The module flex-cuda-pt's Vulkan renderer imports, loadable by this Slang version alone, vendored with the CUDA header.
# It embeds the source's path, as given here, and debug information its absolute one, which it leaves out.
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

build/parity-cpu: tests/parity.cpp build/cpp/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -Ibuild/cpp $< -o $@

build/albedo-cpu: tests/albedo.cpp build/cpp/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -Ibuild/cpp $< -o $@

# The walk's side and sky weights on the CPU, the hooks its other code calls, which no test defines, linked away
build/cpp-restir/pathtracer.cpp: $(SOURCE) $(SLANGC)
	mkdir -p build/cpp-restir
	$(SLANGC) $(SLANGFLAGS) -DFK_RESTIR=1 -DFK_FCPT_WALK=1 $< -target cpp -o $@

build/terminator-cpu: tests/terminator.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/cones-cpu: tests/cones.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -Wl,--gc-sections -Ibuild/cpp-restir $< -o $@

build/coverage-cpu: tests/coverage.cpp build/cpp-restir/pathtracer.cpp
	$(CXX) -std=c++20 -O2 -ffunction-sections -Wl,--gc-sections -Ibuild/cpp-restir \
		-DGENERATED='"build/cpp-restir/pathtracer.cpp"' $< -o $@

# With flex-cuda-pt's structs the header leaves to it
build/parity-cuda: tests/parity.cpp build/cuda/pathtracer.cuh build/cuda/slang-cuda-prelude.h $(REFERENCE)/renderer.h
	$(NVCC) -std=c++20 -O2 -x cu -Ibuild/cuda -I$(REFERENCE) $< -o $@

$(ACTIONLINT):
	mkdir -p .deps
	curl -sSfL https://github.com/rhysd/actionlint/releases/download/v$(ACTIONLINT_VERSION)/actionlint_$(ACTIONLINT_VERSION)_linux_amd64.tar.gz \
		| tar -xz -C .deps actionlint

.PHONY: all lint test test-cpu test-wgsl test-cuda test-vulkan golden-wgsl deploy-local clean
lint: $(ACTIONLINT)
	$(ACTIONLINT)

test: test-cpu test-wgsl test-vulkan

# What only FlexLight had against its goldens, but what draws random numbers
test-cpu: build/parity-cpu build/albedo-cpu build/terminator-cpu build/coverage-cpu build/cones-cpu
	$< < tests/golden-cuda.txt > build/cpu.txt
	build/albedo-cpu
	build/terminator-cpu
	build/coverage-cpu
	build/cones-cpu
	node tests/compare.mjs tests/golden-cuda.txt build/cpu.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/cpu.txt 58

test-wgsl: build/wgsl/pathtracer.wgsl
	node tests/wgsl.mjs $< < tests/golden-wgsl.txt > build/wgsl.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/wgsl.txt

test-cuda: build/parity-cuda  # On the GPU
	$< < tests/golden-cuda.txt > build/cuda.txt
	node tests/compare.mjs tests/golden-cuda.txt build/cuda.txt
	node tests/compare.mjs tests/golden-wgsl.txt build/cuda.txt 58

test-vulkan: tests/vulkan.slang build/cuda/pathtracer.slang-module build/cuda-restir/pathtracer.slang-module \
		build/restir-passes/pathtracer.slang-module  # Compile and validate only
	$(SLANGC) -Ibuild/cuda -warnings-as-errors 30081 $< -target spirv -o build/vulkan.spv
	spirv-val --target-env vulkan1.3 build/vulkan.spv
	$(SLANGC) -Ibuild/cuda-restir -DFK_RESTIR=1 -warnings-as-errors 30081 $< -target spirv -o build/vulkan-restir.spv
	spirv-val --target-env vulkan1.3 build/vulkan-restir.spv
	$(SLANGC) -Ibuild/restir-passes -DFK_RESTIR=1 -DFK_RESTIR_PASSES=1 -warnings-as-errors 30081 $< -target spirv \
		-o build/vulkan-passes.spv
	spirv-val --target-env vulkan1.3 build/vulkan-passes.spv

# On the grid of the CUDA goldens
golden-wgsl: tests/wgsl.mjs tests/golden-cuda.txt $(WGSL_REFERENCE)
	node tests/wgsl.mjs $(WGSL_REFERENCE) --flexlight < tests/golden-cuda.txt > tests/golden-wgsl.txt

# Into sibling checkouts, as CI does into the consumer repos
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
