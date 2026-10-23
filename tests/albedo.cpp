#include <stdio.h>
#include "pathtracer.cpp"
#include "lobes.h"

int main() {
    const float COSINES[] = {1, 0.5f, 0.2f};
    const Material MATERIALS[] = {{Vector<float, 3>(1, 1, 1), Vector<float, 3>(0, 0, 0), 0.5f, 1, 0, 1.5f},
        {Vector<float, 3>(1, 1, 1), Vector<float, 3>(0, 0, 0), 0.2f, 0, 0, 1.5f},
        {Vector<float, 3>(1, 1, 1), Vector<float, 3>(0, 0, 0), 1, 0, 0, 1.5f}};
    const float ALBEDOS[][3] = {{0.9158f, 0.8551f, 0.8315f}, {0.9998f, 0.9990f, 0.9877f}, {0.9209f, 0.9420f, 0.9478f}};
    int failed = 0;
    for (int m = 0; m < 3; m++) for (int k = 0; k < 3; k++) {
        double sum = 0;
        const Vector<float, 3> in_dir(sqrtf(1 - COSINES[k] * COSINES[k]), 0, -COSINES[k]), n(0, 0, 1);
        for (unsigned i = 0; i < 1u << 18; i++)
            sum += sampleBSDF(in_dir, n, MATERIALS[m], 1, 1.5f, hash(i), Vector<float, 2>(0, 0)).throughput.x;
        printf("albedo of material %d at cosine %g: %.4f, exact %.4f\n", m, COSINES[k], sum / (1 << 18), ALBEDOS[m][k]);
        failed |= fabs(sum / (1 << 18) - ALBEDOS[m][k]) > 0.01;
    }
    return failed;
}
