// Evaluates the generated functions on the inputs of each golden line and prints them with its outputs in the golden
// format: on the CPU from Slang's C++ target, or on the GPU from the CUDA header when built as CUDA
#include <stdio.h>
#include <vector>
#ifdef __CUDACC__
#include "renderer.h"
#include "pathtracer.cuh"
typedef float3 Vec;
typedef float2 Vec2;
// FlexLight's Material, as flex-cuda-pt names it
typedef BSDFMaterial Mat;
__device__ Vec vec(const float* a) { return make_float3(a[0], a[1], a[2]); }
__device__ Vec2 vec2(const float* a) { return make_float2(a[0], a[1]); }
__device__ float rnorm(const float* a) { return rnorm3df(a[0], a[1], a[2]); }
#else
#include "pathtracer.cpp"
#define __device__
#define __global__
typedef Vector<float, 3> Vec;
typedef Vector<float, 2> Vec2;
typedef Material Mat;
Vec vec(const float* a) { return Vec(a[0], a[1], a[2]); }
Vec2 vec2(const float* a) { return Vec2(a[0], a[1]); }
float rnorm(const float* a) { return 1 / sqrtf(a[0] * a[0] + a[1] * a[1] + a[2] * a[2]); }
#endif

// in_dir out_dir n g_n albedo metallic roughness transparency eta_i eta_o
struct Case { float in[20]; unsigned random_state; };
struct Result {
    unsigned hash, stream, pcg_state; float pcg_value, greyscale, smith_g1, trowbridge_reitz, fresnel;
    unsigned h_state; Vec h, cosine_hemisphere, tangent_to_world, world_to_tangent, vndf, safe_divide;
    unsigned normal_state; float normal_value; unsigned sphere_state; Vec sphere; unsigned hemisphere_state; Vec hemisphere;
    float g1; Vec normal_map; BSDFLobes lobes; Vec lobe_throughput[3]; float lobe_density[3]; SampleBSDF sample;
    Vec connected[3]; float connected_pdf[3]; Vec bsdf; unsigned nee; Reservoir r; Selection sel; unsigned path;
};

__device__ float dot3(Vec a, Vec b) { return a.x * b.x + a.y * b.y + a.z * b.z; }

__device__ Result evaluate(const Case& c) {
    const Vec in_dir = vec(c.in), out_dir = vec(c.in + 3), n = vec(c.in + 6), albedo = vec(c.in + 12);
    const float alpha = c.in[16] * c.in[16], n_dot_in = dot3(n, in_dir), n_dot_v = - n_dot_in;
    const float sign = float((n_dot_v > 0) - (n_dot_v < 0));
    const float minus_in[] = {- c.in[0], - c.in[1], - c.in[2]}, n_i[] = {n.x * sign, n.y * sign, n.z * sign};
    const Random p = pcg(c.random_state);
    Result r = {hash(c.random_state), stream(c.random_state, 64u), p.state, p.value, rgb_to_greyscale(albedo),
        smithG1(alpha, fabsf(n_dot_in)), trowbridgeReitz(alpha, fabsf(dot3(n, out_dir))),
        fresnel(fabsf(n_dot_in), c.in[18], c.in[19]), c.random_state};
    r.h = sampleHalfVector(vec(minus_in), vec(n_i), alpha, &r.h_state);
    r.cosine_hemisphere = sampleCosWeightedHemisphere(albedo.x, albedo.y);
    r.tangent_to_world = tangentToWorld(out_dir, n);
    r.world_to_tangent = worldToTangent(out_dir, n);
    const float ve[] = {out_dir.x, out_dir.y, fabsf(out_dir.z)};
    r.vndf = sampleGGXVNDF(vec(ve), alpha, albedo.x, albedo.z);
    const float divisor[] = {c.in[15], c.in[17], c.in[16]};
    r.safe_divide = safeDivide(albedo, vec(divisor));
    const Random normal = normal_distribution(c.random_state);
    const RandomSphere sphere = random_sphere(c.random_state);
    const RandomHemisphere hemisphere = random_hemisphere(c.random_state, n);
    r.normal_state = normal.state;
    r.normal_value = normal.value;
    r.sphere_state = sphere.state;
    r.sphere = sphere.value;
    r.hemisphere_state = hemisphere.state;
    r.hemisphere = hemisphere.value;
    // As tests/wgsl.mjs evaluates FlexLight's normal map, BSDF and resampling
    r.g1 = G1(alpha, fabsf(n_dot_in));
    const float uv[][2] = {{c.in[12], c.in[13]}, {c.in[12] + 0.5f, c.in[13] + 0.1f * c.in[14]},
        {c.in[12] + 0.2f * c.in[12], c.in[13] + 0.6f}};
    r.normal_map = tangentToWorldNormalMap(out_dir, normalMapTBN(in_dir, out_dir, vec(c.in + 9), vec2(uv[0]), vec2(uv[1]),
        vec2(uv[2]), n));
    const float zero[] = {0, 0, 0};
    const Mat material = {albedo, vec(zero), c.in[16], c.in[15], c.in[17], fmaxf(c.in[18], c.in[19])};
    const float h[] = {minus_in[0] + c.in[3], minus_in[1] + c.in[4], minus_in[2] + c.in[5]}, scale = rnorm(h);
    const float ggx_n[] = {h[0] * scale, h[1] * scale, h[2] * scale};
    r.lobes = bsdfLobes(in_dir, vec(minus_in), vec(n_i), vec(ggx_n), material, c.in[18], c.in[19]);
    const float p_lobe[] = {r.lobes.p_diffuse, r.lobes.p_refract, r.lobes.p_reflect};
    for (unsigned lobe = 0; lobe < 3; lobe++) {
        const bool side = lobe == 1 ? dot3(vec(n_i), out_dir) < 0 : dot3(vec(n_i), out_dir) > 0;
        r.lobe_throughput[lobe] = p_lobe[lobe] > 1e-6f && side ? lobeThroughput(out_dir, vec(n_i), alpha, material, r.lobes,
            lobe) : vec(zero);
        r.lobe_density[lobe] = lobeDensity(dot3(vec(n_i), out_dir), dot3(out_dir, vec(ggx_n)), fabsf(n_dot_v), alpha,
            r.lobes, c.in[18], c.in[19], lobe);
    }
    r.sample = sampleBSDF(in_dir, n, material, c.in[18], c.in[19], c.random_state, Vec2{});
    for (unsigned lobe = 0; lobe < 3; lobe++) {
        const SampleBSDF s = connectBSDF(in_dir, out_dir, n, material, c.in[18], c.in[19], lobe, c.random_state);
        const float weighted[] = {s.throughput.x * s.pdf, s.throughput.y * s.pdf, s.throughput.z * s.pdf};
        r.connected[lobe] = vec(weighted);
        r.connected_pdf[lobe] = s.pdf;
    }
    r.bsdf = BSDF(in_dir, out_dir, n, vec(c.in + 9), material, c.in[18], c.in[19], c.random_state);
    r.nee = neeDecision(material, n_dot_v, c.in[18], c.in[19]);
    Reservoir a = {}, b = {};
    const float turned[] = {c.in[13], c.in[14], c.in[12]};
    a.seed = c.random_state; a.f = albedo; a.w = 0.5f + c.in[15]; a.jac = 2;
    b.seed = hash(c.random_state); b.f = vec(turned); b.w = 1.5f; b.jac = 0.25f + c.in[16];
    r.sel = {};
    r.sel.random_state = c.random_state;
    offerShifted(&r.sel, a, Shift{albedo, 1}, 0.3f + 0.4f * c.in[16]);
    const float shifted[] = {fabsf(c.in[3]), fabsf(c.in[4]), fabsf(c.in[5])};
    offerShifted(&r.sel, b, Shift{vec(shifted), 0.5f + c.in[17]}, 0.6f);
    r.r = finalize(r.sel, 3);
    r.path = withEnd(r.r, 1, 3, albedo).path;
    return r;
}

__global__ void kernel(const Case* cases, Result* results, unsigned count) {
#ifdef __CUDACC__
    const unsigned i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < count) results[i] = evaluate(cases[i]);
#else
    for (unsigned i = 0; i < count; i++) results[i] = evaluate(cases[i]);
#endif
}

static void print(Vec a) { printf(" %.9g %.9g %.9g", a.x, a.y, a.z); }

int main() {
    std::vector<Case> cases;
    for (Case c; scanf("%f", c.in) == 1; cases.push_back(c)) {
        for (int i = 1; i < 20; i++) scanf("%f", c.in + i);
        scanf("%u%*[^\n]", &c.random_state);
    }
    std::vector<Result> results(cases.size());
#ifdef __CUDACC__
    Case* device_cases;
    Result* device_results;
    cudaMalloc(&device_cases, cases.size() * sizeof(Case));
    cudaMalloc(&device_results, results.size() * sizeof(Result));
    cudaMemcpy(device_cases, cases.data(), cases.size() * sizeof(Case), cudaMemcpyHostToDevice);
    kernel<<<(cases.size() + 63) / 64, 64>>>(device_cases, device_results, cases.size());
    cudaMemcpy(results.data(), device_results, results.size() * sizeof(Result), cudaMemcpyDeviceToHost);
#else
    kernel(cases.data(), results.data(), cases.size());
#endif
    for (size_t i = 0; i < cases.size(); i++) {
        const Case& c = cases[i];
        const Result& r = results[i];
        for (float x : c.in) printf(" %.9g", x);
        printf(" %u", c.random_state);
        printf(" %u %u %u %.9g %.9g", r.hash, r.stream, r.pcg_state, r.pcg_value, r.greyscale);
        printf(" %.9g %.9g %.9g", r.smith_g1, r.trowbridge_reitz, r.fresnel);
        printf(" %u", r.h_state); print(r.h);
        print(r.cosine_hemisphere); print(r.tangent_to_world); print(r.world_to_tangent); print(r.vndf);
        print(r.safe_divide);
        printf(" %u %.9g %u", r.normal_state, r.normal_value, r.sphere_state); print(r.sphere);
        printf(" %u", r.hemisphere_state); print(r.hemisphere);
        const BSDFLobes& l = r.lobes;
        printf(" %.9g", r.g1); print(r.normal_map);
        printf(" %.9g %.9g", l.v_dot_h, l.n_dot_h); print(l.refracted); print(l.F);
        printf(" %.9g %.9g %.9g %.9g %.9g %.9g %.9g %.9g", l.F_greyscale, l.reflect_weight, l.diffuse_weight,
            l.refract_weight, l.colorless_reflection, l.p_diffuse, l.p_reflect, l.p_refract);
        for (unsigned lobe = 0; lobe < 3; lobe++) { print(r.lobe_throughput[lobe]); printf(" %.9g", r.lobe_density[lobe]); }
        print(r.sample.unit_direction); print(r.sample.throughput);
        printf(" %u %u %u %.9g", r.sample.random_state, r.sample.refracted, r.sample.lobe, r.sample.pdf);
        for (unsigned lobe = 0; lobe < 3; lobe++) { print(r.connected[lobe]); printf(" %.9g", r.connected_pdf[lobe]); }
        print(r.bsdf); printf(" %u", r.nee);
        printf(" %u %.9g %.9g", r.r.seed, r.r.w, r.r.c); print(r.r.f); printf(" %.9g %.9g", r.r.jac, r.sel.w_sum);
        print(r.sel.color); printf(" %u %u", r.sel.random_state, r.path);
        printf("\n");
    }
}
