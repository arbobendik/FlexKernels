module random;

import math;

__extern_cpp public struct Random {
    __extern_cpp public uint state;
    __extern_cpp public float value;
};

__extern_cpp public struct RandomSphere {
    __extern_cpp public uint state;
    __extern_cpp public float3 value;
};

__extern_cpp public struct RandomHemisphere {
    __extern_cpp public uint state;
    __extern_cpp public float3 value;
};

[CudaDeviceExport] public func rgb_to_greyscale(rgb: float3) -> float {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

// Target plumbing: flex-cuda-pt's generator for every target but WGSL, as renderer.cu defines it
float random(inout uint state) { return ((state = hash(state)) >> 8) * 0x1p-24f; }

// Target plumbing: declared as in C, as random advances state in place, which func's parameters don't allow
[CudaDeviceExport] public Random pcg(uint state) {
    // Target plumbing: FlexLight's generator for WGSL, flex-cuda-pt's for every other target
    __target_switch {
    case wgsl:
        // PCG random number generator
        // Reference: http://www.pcg-random.org/
        var new_state: uint = state * 747796405u + 2891336453u;
        let word: uint = ((new_state >> ((new_state >> 28u) + 4u)) ^ new_state) * 277803737u;
        let result: uint = (word >> 22u) ^ word;
        // Return random f32 between 0 and 1
        let random: float = float(result) / float(UINT_MAX);
        return Random(new_state, random);
    default:
        const float value = random(state);
        return Random(state, value);
    }
}

[CudaDeviceExport] public func normal_distribution(state: uint) -> Random {
    let r1: Random = pcg(state);
    let r2: Random = pcg(r1.state);
    // Sample normal distribution
    let theta: float = 2.0f * PI * r1.value;
    let rho: float = sqrt(-2.0f * clamp(log(r2.value), - MAX_SAFE_INTEGER_FOR_F32, 0.0f));
    return Random(r2.state, rho * cos(theta));
}

[CudaDeviceExport] public func random_sphere(state: uint) -> RandomSphere {
    let x: Random = normal_distribution(state);
    let y: Random = normal_distribution(x.state);
    let z: Random = normal_distribution(y.state);
    return RandomSphere(z.state, normalize(float3(x.value, y.value, z.value)));
}

[CudaDeviceExport] public func random_hemisphere(state: uint, normal: float3) -> RandomHemisphere {
    let random_sphere: RandomSphere = random_sphere(state);
    // If the random sphere is in the same hemisphere as the normal, return it
    if(dot(random_sphere.value, normal) > 0.0f) {
        return RandomHemisphere(random_sphere.state, random_sphere.value);
    } else {
        // Otherwise, return the opposite direction
        return RandomHemisphere(random_sphere.state, - random_sphere.value);
    }
}

// Target plumbing: hash and stream here instead of among FlexLight's ReSTIR helpers (pathtracer-compute.wgsl:1854),
// as random needs hash in this module, which compiles alone for the rasterizer and so can't import bsdf
[CudaDeviceExport] public func hash(x: uint) -> uint {
    let state: uint = x * 747796405u + 2891336453u;
    let word: uint = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

[CudaDeviceExport] public func stream(seed: uint, index: uint) -> uint {
    return hash(seed ^ hash(index));
}
