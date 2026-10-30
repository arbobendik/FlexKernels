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
    // Sheen: alone over black, its albedo E by midpoint quadrature over the hemisphere, which sheenAlbedo's table is
    // nowhere below, sampling returns E over max(1, its table's); over white diffuse, at most and within 1% of all it
    // receives; each sample with the density and throughput connectBSDF and BSDF give its direction
    const float ROUGHNESSES[] = {0.05f, 0.1f, 0.3f, 0.5f, 1}, VIEWS[] = {1, 0.5f, 0.2f, 0.02f};
    for (const float r : ROUGHNESSES) for (const float mu : VIEWS) {
        const Vector<float, 3> in_dir(sqrtf(1 - mu * mu), 0, -mu), v(-in_dir.x, 0, mu);
        double albedo = 0, alone = 0, over = 0, worst = 0;
        for (int i = 0; i < 512; i++) for (int j = 0; j < 1024; j++) {
            const float t = (i + 0.5f) / 512 * PI / 2, phi = (j + 0.5f) / 1024 * 2 * PI;
            const Vector<float, 3> l(sinf(t) * cosf(phi), sinf(t) * sinf(phi), cosf(t));
            albedo += sheenBRDF(l, v, n, r) * cosf(t) * sinf(t) * (PI / 2 / 512) * (2 * PI / 1024);
        }
        const float table = sheenAlbedo(mu, r);
        const Material SHEEN[] = {{ZERO, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ZERO, ONE, r},
            {ONE, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ZERO, ONE, r}};
        for (unsigned i = 0; i < 1u << 18; i++) {
            const SampleBSDF s = sampleBSDF(in_dir, n, SHEEN[0], 1, 1, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF w = sampleBSDF(in_dir, n, SHEEN[1], 1, 1, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF c = connectBSDF(in_dir, w.unit_direction, n, SHEEN[1], 1, 1, w.lobe, hash(i));
            const float f = BSDF(in_dir, w.unit_direction, n, n, SHEEN[1], 1, 1, hash(i)).x;
            alone += s.throughput.x / (1 << 18), over += w.throughput.x / (1 << 18);
            if (w.pdf > 0) worst = fmax(worst, fmax(fabs(c.pdf / w.pdf - 1), fabs(f / (w.throughput.x * w.pdf) - 1)));
        }
        const double expect = albedo / fmax(1, table);
        printf("sheen %g at cosine %g: albedo %.4f, table %.4f, alone %.4f of %.4f, over white %.4f, worst mismatch %.2g\n",
            r, mu, albedo, table, alone, expect, over, worst);
        failed |= table < albedo * 0.999 || fabs(alone - expect) > 0.01 * fmax(expect, 0.05) || over > 1.002
            || over < 0.99 || worst > 1e-5;
    }
    // Colored sheens, pure red and blue by weights 0.4 and 1, over white diffuse and a white metal near smooth: every
    // channel at most and within 1% of all it receives, to four standard errors of its mean, the base scaled per channel
    // by what the sheen takes
    const Vector<float, 3> TINTS[] = {Vector<float, 3>(1, 0, 0), Vector<float, 3>(0, 0, 1)};
    const float WEIGHTS[] = {0.4f, 1}, TINTED_ROUGHNESSES[] = {0.1f, 0.5f}, TINTED_VIEWS[] = {1, 0.2f, 0.02f};
    for (const float weight : WEIGHTS) for (const Vector<float, 3> tint : TINTS) for (int metal = 0; metal < 2; metal++)
    for (const float r : TINTED_ROUGHNESSES) for (const float mu : TINTED_VIEWS) {
        const Vector<float, 3> in_dir(sqrtf(1 - mu * mu), 0, -mu);
        const Material colored = {ONE, ZERO, metal ? 0.01f : 1, float(metal), 0, 1, ZERO, ONE, 1, ZERO,
            Vector<float, 3>(tint.x * weight, tint.y * weight, tint.z * weight), r};
        double sum[3] = {}, squares[3] = {};
        for (unsigned i = 0; i < 1u << 18; i++) {
            const Vector<float, 3> t = sampleBSDF(in_dir, n, colored, 1, 1, hash(i), Vector<float, 2>(0, 0)).throughput;
            const double c[3] = {t.x, t.y, t.z};
            for (int k = 0; k < 3; k++) sum[k] += c[k] / (1 << 18), squares[k] += c[k] * c[k] / (1 << 18);
        }
        bool bad = false;
        for (int k = 0; k < 3; k++) {
            const double error = 4 * sqrt(fmax(squares[k] - sum[k] * sum[k], 0) / (1 << 18));
            bad |= sum[k] > 1 + error || sum[k] < 0.99 - error;
        }
        printf("colored sheen %g %g %g over %s, r %g, cosine %g: %.4f %.4f %.4f%s\n", tint.x * weight, tint.y * weight,
            tint.z * weight, metal ? "metal" : "diffuse", r, mu, sum[0], sum[1], sum[2], bad ? " FAILED" : "");
        failed |= bad;
    }
    return failed;
}
