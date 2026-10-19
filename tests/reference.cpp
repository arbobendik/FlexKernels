// Goldens of the CUDA functions FlexKernels shares on a seeded grid of directions, normals, surfaces and IORs, one case per
// line: the inputs in_dir out_dir n g_n albedo metallic roughness transparency eta_i eta_o random_state, then the outputs
// in the order of tests/parity.cpp
// The allowed change: D without cancellation, floored at the least normal float
#define trowbridgeReitz floorTrowbridgeReitz
#include "renderer.cu"
#undef trowbridgeReitz
#include <stdio.h>

static float trowbridgeReitz(float alpha, float n_dot_h) {
    const float numerator = alpha * alpha, denom = (1 - n_dot_h) * (1 + n_dot_h) + numerator * n_dot_h * n_dot_h;
    return numerator / fmaxf(PI * denom * denom, 1.17549435e-38f);
}

static float3 unit(unsigned& state) {
    const float z = 2 * random(state) - 1, phi = 2 * PI * random(state), r = sqrtf(fmaxf(0, 1 - z * z));
    return make_float3(r * cosf(phi), r * sinf(phi), z);
}

static void print(float3 a) { printf(" %.9g %.9g %.9g", a.x, a.y, a.z); }

int main() {
    const float ROUGHNESS[] = {0, 0.05f, 0.5f, 1}, METALLIC[] = {0, 1}, TRANSPARENCY[] = {0, 0.5f, 1};
    // Entering, leaving with total internal reflection at grazing angles and without index change
    const float ETA[][2] = {{1, 1.5f}, {1.5f, 1}, {1, 1}};
    unsigned state = 1;
    for (float roughness : ROUGHNESS) for (float metallic : METALLIC) for (float transparency : TRANSPARENCY)
    for (const auto& eta : ETA) for (int kind = 0; kind < 4; kind++) {
        const float3 n = unit(state);
        float3 in_dir = unit(state), out_dir = unit(state), g_n = n;
        // Grazing incidence from either side, then also grazing exitance, apart so that the half vector is not tangent
        if (kind >= 2) in_dir = normalize(normalize(cross(n, in_dir)) + n * (0.001f * sign(dot(n, in_dir))));
        if (kind == 3) out_dir = normalize(normalize(cross(n, out_dir)) + n * (0.003f * sign(dot(n, out_dir))));
        // Geometry normal apart from the smooth one
        if (kind % 2) g_n = normalize(n + unit(state) * 0.3f);
        const float3 albedo = make_float3(random(state), random(state), random(state));
        const unsigned random_state = hash(state++);
        print(in_dir); print(out_dir); print(n); print(g_n); print(albedo);
        printf(" %.9g %.9g %.9g %.9g %.9g %u", metallic, roughness, transparency, eta[0], eta[1], random_state);
        const float alpha = roughness * roughness;
        const float3 v = - in_dir, n_i = n * sign(dot(n, v));
        const Random p = pcg(random_state);
        printf(" %u %u %u %.9g %.9g", hash(random_state), stream(random_state, 64u), p.state, p.value,
            rgb_to_greyscale(albedo));
        printf(" %.9g %.9g %.9g", smithG1(alpha, fabsf(dot(n, in_dir))), trowbridgeReitz(alpha, fabsf(dot(n, out_dir))),
            fresnel(fabsf(dot(n, in_dir)), eta[0], eta[1]));
        unsigned h_state = random_state;
        const float3 h = sampleHalfVector(v, n_i, alpha, h_state);
        printf(" %u", h_state); print(h);
        print(sampleCosWeightedHemisphere(albedo.x, albedo.y));
        print(tangentToWorld(out_dir, n)); print(worldToTangent(out_dir, n));
        // From above the surface, as sampleHalfVector views it
        print(sampleGGXVNDF(make_float3(out_dir.x, out_dir.y, fabsf(out_dir.z)), alpha, albedo.x, albedo.z));
        print(safeDivide(albedo, make_float3(metallic, transparency, roughness)));
        const Random normal = normal_distribution(random_state);
        const RandomSphere sphere = random_sphere(random_state);
        const RandomHemisphere hemisphere = random_hemisphere(random_state, n);
        printf(" %u %.9g %u", normal.state, normal.value, sphere.state); print(sphere.value);
        printf(" %u", hemisphere.state); print(hemisphere.value);
        printf("\n");
    }
}
