// Directional albedo by sampleBSDF on the CPU, the mean throughput of its samples, at incidence cosines 1, 0.5 and 0.2:
// of a white metal of roughness 0.5, GGX's single-scatter albedo under exact Smith masking, and of white opaque
// dielectrics of IOR 1.5 and roughness 0.2 and 1, the diffuse's 1 - F of the dielectric over the visible normals plus
// that reflection's single-scatter albedo, never above one, and of a gray metal of roughness 0.2 transmitting fully,
// which refracts nothing and reflects half of what a white metal does; all integrated numerically. Then Blender's
// Specular IOR Level and Tint: a smooth black dielectric of IOR 1.5 at normal incidence reflects 0.04 times the factor
// the level gives and the tint, and a white one of roughness 0.2, its reflectance doubled and tinted, at most what it
// receives in each channel; one of IOR 10, its reflectance doubled past total, at most all of it, and smooth white glass
// without reflectance, light leaving it past the critical angle, all of it, as the true IOR refracts none
#include <stdio.h>
#include "pathtracer.cpp"

int main() {
    const float COSINES[] = {1, 0.5f, 0.2f};
    const Vector<float, 3> ZERO(0, 0, 0), ONE(1, 1, 1);  // No absorption, an untinted specular
    const Material MATERIALS[] = {{ONE, ZERO, 0.5f, 1, 0, 1.5f, ZERO, ONE, 1}, {ONE, ZERO, 0.2f, 0, 0, 1.5f, ZERO, ONE, 1},
        {ONE, ZERO, 1, 0, 0, 1.5f, ZERO, ONE, 1}, {Vector<float, 3>(0.5f, 0.5f, 0.5f), ZERO, 0.2f, 1, 1, 1.5f, ZERO, ONE, 1}};
    const float ALBEDOS[][3] = {{0.9158f, 0.8551f, 0.8315f}, {0.9998f, 0.9990f, 0.9877f}, {0.9209f, 0.9420f, 0.9478f},
        {0.4992f, 0.4978f, 0.4875f}};
    int failed = 0;
    for (int m = 0; m < 4; m++) for (int k = 0; k < 3; k++) {
        double sum = 0;
        const Vector<float, 3> in_dir(sqrtf(1 - COSINES[k] * COSINES[k]), 0, -COSINES[k]), n(0, 0, 1);
        for (unsigned i = 0; i < 1u << 18; i++)
            sum += sampleBSDF(in_dir, n, MATERIALS[m], 1, 1.5f, hash(i), Vector<float, 2>(0, 0)).throughput.x;
        printf("albedo of material %d at cosine %g: %.4f, exact %.4f\n", m, COSINES[k], sum / (1 << 18), ALBEDOS[m][k]);
        failed |= fabs(sum / (1 << 18) - ALBEDOS[m][k]) > 0.01;
    }
    const Vector<float, 3> TINT(1, 0.5f, 0.25f), RED(1, 0, 0), normal(0, 0, -1), grazing(0.98f, 0, -0.2f), n(0, 0, 1);
    const Material SPECULAR[] = {{ZERO, ZERO, 0.001f, 0, 0, 1.5f, ZERO, ONE, 2}, {ZERO, ZERO, 0.001f, 0, 0, 1.5f, ZERO, ONE, 0},
        {ZERO, ZERO, 0.001f, 0, 0, 1.5f, ZERO, RED, 1}, {ONE, ZERO, 0.2f, 0, 0, 1.5f, ZERO, TINT, 2},
        {ZERO, ZERO, 0.001f, 0, 0, 10, ZERO, ONE, 2}, {ONE, ZERO, 0.001f, 0, 1, 1.5f, ZERO, ONE, 0}};
    const float REFLECTED[][3] = {{0.08f, 0.08f, 0.08f}, {0, 0, 0}, {0.04f, 0, 0}};
    for (int m = 0; m < 6; m++) {
        double sum[3] = {};
        for (unsigned i = 0; i < 1u << 18; i++) {
            const Vector<float, 3> t = sampleBSDF(m == 5 ? grazing : normal, n, SPECULAR[m], m == 5 ? 1.5f : 1,
                m == 5 ? 1 : SPECULAR[m].ior, hash(i), Vector<float, 2>(0, 0)).throughput;
            sum[0] += t.x / (1 << 18), sum[1] += t.y / (1 << 18), sum[2] += t.z / (1 << 18);
        }
        printf("specular %d: %.4f %.4f %.4f\n", m, sum[0], sum[1], sum[2]);
        for (int c = 0; c < 3; c++) failed |= m < 3 ? fabs(sum[c] - REFLECTED[m][c]) > 0.002f
            : sum[c] > 1.002f || (m > 3 && sum[c] < 0.99f);
    }
    return failed;
}
