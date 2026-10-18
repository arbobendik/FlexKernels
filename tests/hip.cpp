// The generated header compiled under hipcc, with the structs it leaves to flex-cuda-pt's renderer.h as a HIP renderer
// would declare them
#include <hip/hip_runtime.h>
struct BSDFMaterial { float3 albedo, emissive; float roughness, metallic, transmission, ior; };
struct Hit { unsigned triangle; float2 uv; };
struct Reservoir { unsigned seed, path; float w, c; float3 f; float jac; Hit rc; float3 dir, radiance; };
struct Shift { float3 f; float jac; };
#include "pathtracer.cuh"
