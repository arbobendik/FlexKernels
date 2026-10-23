// Directional albedo of a white metal of roughness 0.5 by sampleBSDF on the CPU, the mean throughput of its samples:
// GGX's single-scatter albedo under exact Smith masking, integrated numerically, at incidence cosines 1, 0.5 and 0.2
#include <stdio.h>
#include "pathtracer.cpp"

int main() {
    const float COSINES[] = {1, 0.5f, 0.2f}, ALBEDOS[] = {0.9158f, 0.8551f, 0.8315f};
    const Material metal = {Vector<float, 3>(1, 1, 1), Vector<float, 3>(0, 0, 0), 0.5f, 1, 0, 1.5f};
    int failed = 0;
    for (int k = 0; k < 3; k++) {
        double sum = 0;
        const Vector<float, 3> in_dir(sqrtf(1 - COSINES[k] * COSINES[k]), 0, -COSINES[k]), n(0, 0, 1);
        for (unsigned i = 0; i < 1u << 18; i++)
            sum += sampleBSDF(in_dir, n, metal, 1, 1.5f, hash(i), Vector<float, 2>(0, 0)).throughput.x;
        printf("albedo at cosine %g: %.4f, exact %.4f\n", COSINES[k], sum / (1 << 18), ALBEDOS[k]);
        failed |= fabs(sum / (1 << 18) - ALBEDOS[k]) > 0.01;
    }
    return failed;
}
