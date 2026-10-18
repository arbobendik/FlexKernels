// The generated header compiled under hipcc, with the struct it leaves to flex-cuda-pt's renderer.h as a HIP renderer
// would declare it
#include <hip/hip_runtime.h>
struct BSDFMaterial { float3 albedo, emissive; float roughness, metallic, transmission, ior; };
#include "pathtracer.cuh"
