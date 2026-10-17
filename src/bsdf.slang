// Microfacet terms and sampling of renderer.cu in flex-cuda-pt and pathtracer-compute.wgsl in FlexLight, on which both
// build their BSDF
module bsdf;

import math;
import random;

// Exact Smith masking of GGX, the visible normal density sampleGGXVNDF draws from
[CudaDeviceExport] public float smithG1(float alpha, float n_dot_x) {
    const float alpha_sq = alpha * alpha;
    return 2.0f * n_dot_x / (n_dot_x + sqrt(alpha_sq + (1.0f - alpha_sq) * n_dot_x * n_dot_x));
}

[CudaDeviceExport] public float trowbridgeReitz(float alpha, float n_dot_h) {
    const float numerator = alpha * alpha;
    const float denom = n_dot_h * n_dot_h * (numerator - 1.0f) + 1.0f;
    return numerator / max(PI * denom * denom, BIAS);
}

[CudaDeviceExport] public float fresnel(float cos_theta, float eta_i, float eta_o) {
    // Compute sini using Snell's law
    const float sin_theta = sqrt(max(0.0f, 1.0f - cos_theta * cos_theta));
    const float sin_psi = (eta_i / eta_o) * sin_theta;
    // Total internal reflection
    float kr = 1.0f;
    if (sin_psi < 1.0f) {
        const float cos_psi = sqrt(max(0.0f, 1.0f - sin_psi * sin_psi));
        const float Rs = ((eta_o * cos_theta) - (eta_i * cos_psi)) / ((eta_o * cos_theta) + (eta_i * cos_psi));
        const float Rp = ((eta_i * cos_theta) - (eta_o * cos_psi)) / ((eta_i * cos_theta) + (eta_o * cos_psi));
        kr = (Rs * Rs + Rp * Rp) / 2.0f;
    }
    return kr;
}

// Sampling of the GGX VNDF
[CudaDeviceExport] public float3 sampleGGXVNDF(float3 Ve, float alpha, float U1, float U2) {
    // The Ve argument is the view direction in tangent space, where the normal is (0, 0, 1).
    // Section 3.2: transforming the view direction to the hemisphere configuration.
    const float3 Vh = normalize(float3(alpha * Ve.x, alpha * Ve.y, Ve.z));
    // Section 4.1: orthonormal basis (with special case if cross product is zero).
    const float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
    const float3 T1 = lensq > 0.0f ? float3(-Vh.y, Vh.x, 0.0f) * rsqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
    const float3 T2 = cross(Vh, T1);
    // Section 4.2: parameterization of the projected area.
    const float r = sqrt(U1);
    const float phi = 2.0f * PI * U2;
    const float t1 = r * cos(phi);
    float t2 = r * sin(phi);
    const float s = 0.5f * (1.0f + Vh.z);
    // Summands swapped, as Slang inlines t2: nvcc then fuses the same product into a multiply-add as in renderer.cu
    t2 = s * t2 + (1.0f - s) * sqrt(max(0.0f, 1.0f - t1 * t1));
    // Section 4.3: reprojection onto hemisphere.
    const float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0f, 1.0f - t1 * t1 - t2 * t2)) * Vh;
    // Section 3.4: transforming the normal back to the ellipsoid configuration.
    return normalize(float3(alpha * Nh.x, alpha * Nh.y, max(0.0f, Nh.z)));
}

// Corresponding PDF is: pdf = cos(theta) / PI
[CudaDeviceExport] public float3 sampleCosWeightedHemisphere(float random_1, float random_2) {
    const float r = sqrt(random_1);
    const float theta = 2.0f * PI * random_2;
    const float x = r * cos(theta);
    const float z = r * sin(theta);
    const float y = sqrt(max(0.0f, 1.0f - x * x - z * z));
    return float3(x, y, z);
}

[CudaDeviceExport] public float3 tangentToWorld(float3 v, float3 n) {
    float3 a = float3(0.0f, 1.0f, 0.0f);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0f, 0.0f, 0.0f);
    }
    const float3 tangent = normalize(cross(n, a));
    const float3 bitangent = cross(n, tangent);
    return v.x * tangent + v.y * n + v.z * bitangent;
}

[CudaDeviceExport] public float3 worldToTangent(float3 v, float3 n) {
    float3 a = float3(0.0f, 1.0f, 0.0f);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0f, 0.0f, 0.0f);
    }
    const float3 tangent = normalize(cross(n, a));
    const float3 bitangent = cross(n, tangent);
    return float3(dot(v, tangent), dot(v, n), dot(v, bitangent));
}

// The visible normal sampleBSDF reflects or refracts about, from two draws of random_state
[CudaDeviceExport] public float3 sampleHalfVector(float3 v, float3 n_i, float alpha, inout uint random_state) {
    // Generate random values for sampling
    const Random random_h_1 = pcg(random_state);
    const Random random_h_2 = pcg(random_h_1.state);
    random_state = random_h_2.state;
    const float3 v_tangent = worldToTangent(v, n_i);
    const float3 ggx_n = sampleGGXVNDF(v_tangent.xzy, alpha, random_h_1.value, random_h_2.value).xzy;
    // Transform half vector back to world space
    return tangentToWorld(ggx_n, n_i);
}
