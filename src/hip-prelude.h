// What the generated code uses of Slang's CUDA prelude, which does not build under hipcc; HIP's vector types bring the
// operators. Copied next to the generated header as slang-cuda-prelude.h.
#pragma once
#include <hip/hip_runtime.h>
typedef unsigned int uint;
__device__ inline float F32_abs(float f) { return fabsf(f); }
__device__ inline float F32_cos(float f) { return cosf(f); }
__device__ inline float F32_log(float f) { return logf(f); }
__device__ inline float F32_max(float a, float b) { return fmaxf(a, b); }
__device__ inline float F32_min(float a, float b) { return fminf(a, b); }
__device__ inline float F32_sin(float f) { return sinf(f); }
__device__ inline float F32_sqrt(float f) { return sqrtf(f); }
__device__ inline float3 make_float3(float f) { return make_float3(f, f, f); }
struct bool3 { bool x, y, z; };
__device__ inline bool3 operator==(float3 a, float3 b) { return {a.x == b.x, a.y == b.y, a.z == b.z}; }
template<typename T> __device__ inline T _slang_select(bool condition, T v0, T v1) { return condition ? v0 : v1; }
__device__ inline float3 _slang_select(bool3 condition, float3 v0, float3 v1) {
    return make_float3(condition.x ? v0.x : v1.x, condition.y ? v0.y : v1.y, condition.z ? v0.z : v1.z);
}
// FlexLight's mat3x3<f32> of the normal map, rows as Slang keeps them; renamed SlangMatrix by the generated header
template<typename T, int ROWS, int COLS> struct Matrix;
template<> struct Matrix<float, 3, 3> { float3 rows[3]; };
template<typename T, int ROWS, int COLS> __device__ inline Matrix<T, ROWS, COLS> makeMatrix(float3 a, float3 b, float3 c) {
    return {{a, b, c}};
}
__device__ inline float _slang_vector_get_element(float3 v, int i) { return i == 0 ? v.x : i == 1 ? v.y : v.z; }
__device__ inline float* _slang_vector_get_element_ptr(float3* v, int i) { return i == 0 ? &v->x : i == 1 ? &v->y : &v->z; }
