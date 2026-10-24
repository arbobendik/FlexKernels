// Directional albedo by sampleBSDF on the CPU, the mean throughput of its samples, at incidence cosines 1, 0.5 and 0.2:
// of a white metal of roughness 0.5, GGX's single-scatter albedo under exact Smith masking, and of white opaque
// dielectrics of IOR 1.5 and roughness 0.2 and 1, the diffuse's 1 - F of the dielectric over the visible normals plus
// that reflection's single-scatter albedo, never above one, and of a gray metal of roughness 0.2 transmitting fully,
// which refracts nothing and reflects half of what a white metal does; all integrated numerically. Then Blender's
// Specular IOR Level and Tint: a smooth black dielectric of IOR 1.5 at normal incidence reflects 0.04 times the factor
// the level gives and the tint, and a white one of roughness 0.2, its reflectance doubled and tinted, at most what it
// receives in each channel; one of IOR 10, its reflectance doubled past total, at most all of it, and smooth white glass
// without reflectance, light leaving it past the critical angle, all of it, as the true IOR refracts none. Last,
// Blender's Translucent BSDF through the diffuse lobe
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
    // Blender's Translucent BSDF, white and half mixed with a white diffuse: all it receives leaves, through to the other
    // side and of the mix half back, each sample with the density and throughput connectBSDF and BSDF give its direction
    const Material TRANSLUCENT[] = {{ZERO, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ONE},
        {Vector<float, 3>(0.5f, 0.5f, 0.5f), ZERO, 1, 0, 0, 1, ZERO, ONE, 1, Vector<float, 3>(0.5f, 0.5f, 0.5f)}};
    for (int m = 0; m < 2; m++) for (int k = 0; k < 3; k++) {
        double sum = 0, through = 0, worst = 0;
        const Vector<float, 3> in_dir(sqrtf(1 - COSINES[k] * COSINES[k]), 0, -COSINES[k]);
        for (unsigned i = 0; i < 1u << 18; i++) {
            const SampleBSDF s = sampleBSDF(in_dir, n, TRANSLUCENT[m], 1, 1, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF c = connectBSDF(in_dir, s.unit_direction, n, TRANSLUCENT[m], 1, 1, 0u, hash(i));
            const float f = translucentBSDF(in_dir, s.unit_direction, n, n, TRANSLUCENT[m], 1, 1, hash(i)).x, back = s.unit_direction.z < 0;
            sum += s.throughput.x, through += back * s.throughput.x;
            failed |= s.refracted != back || (m == 0 && !back);
            worst = fmax(worst, fmax(fabs(c.pdf / s.pdf - 1), fabs(f / (s.throughput.x * s.pdf) - 1)));
        }
        printf("translucent %d at cosine %g: %.4f, through %.4f, worst density or BSDF mismatch %.2g\n", m, COSINES[k],
            sum / (1 << 18), through / (1 << 18), worst);
        failed |= fabs(sum / (1 << 18) - 1) > 0.002f || fabs(through / (1 << 18) - (m ? 0.5f : 1)) > 0.01f || worst > 1e-5;
    }
    // The mix under a shading normal tilted from its face: in 64 bins of equal solid angle, the share of samples on the
    // side of the face the shading normal sends them to is connectBSDF's density integrated over the bin, where both sides
    // agree, as next event estimation weighs it; and that of the rest, mirrored across the face as renderer.cu carries
    // them on, the density integrated at the mirror image, so the mirror keeps their mass
    const Vector<float, 3> tilted(0.95f, 0, 0.3122499f), above(0.3f / 1.044f, 0, -1 / 1.044f);
    constexpr float PI = 3.14159265f;
    const auto dot = [](Vector<float, 3> a, Vector<float, 3> b) { return a.x * b.x + a.y * b.y + a.z * b.z; };
    const auto bin = [](Vector<float, 3> d) { return int(fmin(7, (d.z + 1) * 4)) * 8 + int(fmin(7, (atan2f(d.y, d.x) + PI) / (2 * PI) * 8)); };
    const auto mirror = [](Vector<float, 3> d) { return Vector<float, 3>(d.x, d.y, -d.z); };
    const auto agrees = [&](Vector<float, 3> d) { return (dot(tilted, d) * dot(tilted, above) > 0) == (d.z < 0); };
    double kept[64] = {}, moved[64] = {}, worst_bin = 0;
    for (unsigned i = 0; i < 1u << 22; i++) {
        const SampleBSDF s = sampleBSDF(above, tilted, TRANSLUCENT[1], 1, 1, hash(i), Vector<float, 2>(0, 0));
        if (agrees(s.unit_direction)) kept[bin(s.unit_direction)] += 1.0 / (1 << 22);
        else moved[bin(mirror(s.unit_direction))] += 1.0 / (1 << 22);
    }
    for (int b = 0; b < 64; b++) {
        double expect_kept = 0, expect_moved = 0;
        for (unsigned j = 0; j < 4096; j++) {  // Uniform points of the bin
            const float z = (b / 8 + (j % 64 + 0.5f) / 64) / 4 - 1, phi = (b % 8 + (j / 64 + 0.5f) / 64) / 8 * 2 * PI - PI;
            const Vector<float, 3> d(sqrtf(1 - z * z) * cosf(phi), sqrtf(1 - z * z) * sinf(phi), z);
            const float pdf = connectBSDF(above, d, tilted, TRANSLUCENT[1], 1, 1, 0u, hash(j)).pdf;
            const float mirrored = connectBSDF(above, mirror(d), tilted, TRANSLUCENT[1], 1, 1, 0u, hash(j)).pdf;
            expect_kept += agrees(d) * pdf * PI / 16 / 4096, expect_moved += !agrees(mirror(d)) * mirrored * PI / 16 / 4096;
        }
        worst_bin = fmax(worst_bin, fmax(fabs(kept[b] - expect_kept), fabs(moved[b] - expect_moved)) / (0.0005 + sqrt(expect_kept / (1 << 22))));
    }
    printf("translucent tilted: worst bin off its density by %.2f of the tolerance\n", worst_bin);
    failed |= worst_bin > 1;
    return failed;
}
