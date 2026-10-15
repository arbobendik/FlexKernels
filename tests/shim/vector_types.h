// Host stand-ins for the CUDA types and intrinsics renderer.cu uses, to capture its goldens without a GPU
#pragma once
#include <math.h>
#define __device__
#define __global__
struct float2 { float x, y; };
struct float3 { float x, y, z; };
struct float4 { float x, y, z, w; };
struct uint3 { unsigned x, y, z; };
struct char2 { signed char x, y; };
inline float2 make_float2(float x, float y) { return {x, y}; }
inline float3 make_float3(float x, float y, float z) { return {x, y, z}; }
inline float4 make_float4(float x, float y, float z, float w) { return {x, y, z, w}; }
inline float rsqrtf(float x) { return 1 / sqrtf(x); }
inline float rnorm3df(float x, float y, float z) { return 1 / sqrtf(x * x + y * y + z * z); }
inline float __uint_as_float(unsigned x) { float f; __builtin_memcpy(&f, &x, 4); return f; }
