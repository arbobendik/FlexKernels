// Evaluates the generated functions on the inputs of each golden line and prints them with its outputs in the golden
// format: on the CPU from Slang's C++ target, or on the GPU from the CUDA header when built as CUDA
#include <stdio.h>
#include <vector>
#ifdef __CUDACC__
#include "pathtracer.cuh"
typedef float3 Vec;
__device__ Vec vec(const float* a) { return make_float3(a[0], a[1], a[2]); }
#else
#include "pathtracer.cpp"
#define __device__
#define __global__
typedef Vector<float, 3> Vec;
Vec vec(const float* a) { return Vec(a[0], a[1], a[2]); }
#endif

// in_dir out_dir n g_n albedo metallic roughness transparency eta_i eta_o
struct Case { float in[20]; unsigned random_state; };
struct Result {
    unsigned hash, stream, pcg_state; float pcg_value, greyscale, smith_g1, trowbridge_reitz, fresnel;
    unsigned h_state; Vec h, cosine_hemisphere, tangent_to_world, world_to_tangent, vndf, safe_divide;
    unsigned normal_state; float normal_value; unsigned sphere_state; Vec sphere; unsigned hemisphere_state; Vec hemisphere;
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
        printf("\n");
    }
}
