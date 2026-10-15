// What the generated code uses of Slang's CUDA prelude, which does not build under hipcc; HIP's vector types bring the
// operators. Copied next to the generated header as slang-cuda-prelude.h.
#pragma once
#include <hip/hip_runtime.h>
typedef unsigned int uint;
__device__ inline float F32_abs(float f) { return fabsf(f); }
__device__ inline float F32_cos(float f) { return cosf(f); }
__device__ inline float F32_max(float a, float b) { return fmaxf(a, b); }
__device__ inline float F32_min(float a, float b) { return fminf(a, b); }
__device__ inline float F32_rsqrt(float f) { return rsqrtf(f); }
__device__ inline float F32_sin(float f) { return sinf(f); }
__device__ inline float F32_sqrt(float f) { return sqrtf(f); }
__device__ inline float3 make_float3(float f) { return make_float3(f, f, f); }
template<typename T, size_t SIZE> struct FixedArray {
    __device__ const T& operator[](size_t index) const { return m_data[index]; }
    __device__ T& operator[](size_t index) { return m_data[index]; }
    T m_data[SIZE];
};
