// Evaluates the generated BSDF on the inputs of each golden line and prints them with its outputs in the golden format:
// on the CPU from Slang's C++ target, or on the GPU from the CUDA header when built as CUDA
#include <stdio.h>
#include <vector>
#ifdef __CUDACC__
#include "bsdf.cuh"
typedef float3 Vec;
__device__ Vec vec(const float* a) { return make_float3(a[0], a[1], a[2]); }
#else
// Slang's exports are extern "C" as glibc's random(), which the prelude declares unless it already is
#include <stdlib.h>
#define random flexkernels_random
#include "bsdf.cpp"
#define __device__
#define __global__
typedef Vector<float, 3> Vec;
Vec vec(const float* a) { return Vec(a[0], a[1], a[2]); }
#endif

// in_dir out_dir n g_n albedo metallic roughness transparency eta_i eta_o
struct Case { float in[20]; unsigned random_state; };
struct Result { Vec f, unit_direction, throughput; unsigned random_state, refracted, lobe; float pdf; Lobe lobes[3]; };

__device__ Result evaluate(const Case& c) {
    Surface s = {};
    s.albedo = vec(c.in + 12);
    s.metallic = c.in[15];
    s.roughness = c.in[16];
    s.transparency = c.in[17];
    const Vec in_dir = vec(c.in), out_dir = vec(c.in + 3), n = vec(c.in + 6), g_n = vec(c.in + 9);
    const SampleBSDF sample = sampleBSDF(in_dir, n, s, c.in[18], c.in[19], c.random_state);
    Result r = {BSDF(in_dir, out_dir, n, g_n, s, c.in[18], c.in[19]), sample.unit_direction, sample.throughput,
        sample.random_state, sample.refracted, sample.lobe, sample.pdf};
    for (unsigned lobe = 0; lobe < 3; lobe++) {
        r.lobes[lobe] = evalLobe(in_dir, out_dir, n, s, c.in[18], c.in[19], lobe, c.random_state);
    }
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
    if (cudaMemcpy(results.data(), device_results, results.size() * sizeof(Result), cudaMemcpyDeviceToHost)) return 1;
#else
    kernel(cases.data(), results.data(), cases.size());
#endif
    for (size_t i = 0; i < cases.size(); i++) {
        const Case& c = cases[i];
        const Result& r = results[i];
        for (float x : c.in) printf(" %.9g", x);
        printf(" %u", c.random_state);
        print(r.f); print(r.unit_direction); print(r.throughput);
        printf(" %u %u %u %.9g", r.random_state, r.refracted, r.lobe, r.pdf);
        for (const Lobe& l : r.lobes) {
            print(l.f_cos);
            printf(" %.9g", l.pdf);
        }
        printf("\n");
    }
}
