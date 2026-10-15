// Never called, the goldens only evaluate the BSDF
#pragma once
#include "vector_types.h"
enum { OPTIX_RAY_FLAG_NONE };
inline void optixTraverse(unsigned long long, float3, float3, float, float, float, unsigned, unsigned, unsigned, unsigned,
    unsigned) {}
inline bool optixHitObjectIsHit() { return false; }
inline float optixHitObjectGetRayTmax() { return 0; }
inline unsigned optixHitObjectGetPrimitiveIndex() { return 0; }
inline unsigned optixHitObjectGetAttribute_0() { return 0; }
inline unsigned optixHitObjectGetAttribute_1() { return 0; }
inline uint3 optixGetLaunchIndex() { return {}; }
inline uint3 optixGetLaunchDimensions() { return {}; }
inline unsigned long long optixGetSbtDataPointer() { return 0; }
