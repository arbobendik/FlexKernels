module random;

import math;

[CudaDeviceExport] public uint hash(uint x) { // PCG
    x = x * 747796405u + 2891336453u;
    x = ((x >> ((x >> 28) + 4)) ^ x) * 277803737u;
    return (x >> 22) ^ x;
}
__extern_cpp public struct Random { __extern_cpp public uint state; __extern_cpp public float value; };
__extern_cpp public struct RandomSphere { __extern_cpp public uint state; __extern_cpp public float3 value; };
__extern_cpp public struct RandomHemisphere { __extern_cpp public uint state; __extern_cpp public float3 value; };
// The state advanced and the value drawn from it, by each consumer's own generator: CUDA advances to the hash and
// draws its 24 high bits, FlexLight advances the LCG state and draws the hash over UINT_MAX
[CudaDeviceExport] public Random pcg(uint state) {
    __target_switch {
    case wgsl: return { state * 747796405u + 2891336453u, float(hash(state)) / float(4294967295u) };
    default:
        const uint next = hash(state);
        return { next, float(next >> 8) * 0x1p-24f };
    }
}
[CudaDeviceExport] public uint stream(uint seed, uint index) { return hash(seed ^ hash(index)); }

[CudaDeviceExport] public Random normal_distribution(uint state) {
    const Random r1 = pcg(state);
    const Random r2 = pcg(r1.state);
    // Sample normal distribution
    const float theta = 2.0f * PI * r1.value;
    const float rho = sqrt(-2.0f * min(max(log(r2.value), - MAX_SAFE_INTEGER_FOR_F32), 0.0f));
    return { r2.state, rho * cos(theta) };
}

[CudaDeviceExport] public RandomSphere random_sphere(uint state) {
    const Random x = normal_distribution(state);
    const Random y = normal_distribution(x.state);
    const Random z = normal_distribution(y.state);
    return { z.state, normalize(float3(x.value, y.value, z.value)) };
}

[CudaDeviceExport] public RandomHemisphere random_hemisphere(uint state, float3 normal) {
    const RandomSphere random_sphere = random_sphere(state);
    // If the random sphere is in the same hemisphere as the normal, return it
    if (dot(random_sphere.value, normal) > 0.0f) {
        return { random_sphere.state, random_sphere.value };
    } else {
        // Otherwise, return the opposite direction
        return { random_sphere.state, - random_sphere.value };
    }
}
