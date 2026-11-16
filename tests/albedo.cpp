#include <stdio.h>
#include "pathtracer.cpp"

int main() {
    const float COSINES[] = {1, 0.5f, 0.2f};
    const Vector<float, 3> ZERO(0, 0, 0), ONE(1, 1, 1);
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
        for (unsigned j = 0; j < 4096; j++) {
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
    const float ROUGHNESSES[] = {0.05f, 0.1f, 0.3f, 0.5f, 1}, VIEWS[] = {1, 0.5f, 0.2f, 0.02f};
    for (const float r : ROUGHNESSES) for (const float mu : VIEWS) {
        const Vector<float, 3> in_dir(sqrtf(1 - mu * mu), 0, -mu), v(-in_dir.x, 0, mu);
        const Material SHEEN[] = {{ZERO, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ZERO, ONE, r},
            {ONE, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ZERO, ONE, r}};
        // By quadrature: the sheen lobe alone, E / max(E_table, 1), and over white, at most 1 where E_table >= E
        double albedo = 0, white = 0, alone = 0, over = 0, worst = 0, alone2 = 0, over2 = 0;
        for (int i = 0; i < 512; i++) for (int j = 0; j < 1024; j++) {
            const float t = (i + 0.5f) / 512 * PI / 2, phi = (j + 0.5f) / 1024 * 2 * PI;
            const Vector<float, 3> l(sinf(t) * cosf(phi), sinf(t) * sinf(phi), cosf(t));
            albedo += BSDF(in_dir, l, n, n, SHEEN[0], 1, 1, 0).x * sinf(t) * (PI / 2 / 512) * (2 * PI / 1024);
            white += BSDF(in_dir, l, n, n, SHEEN[1], 1, 1, 0).x * sinf(t) * (PI / 2 / 512) * (2 * PI / 1024);
        }
        for (unsigned i = 0; i < 1u << 18; i++) {
            const SampleBSDF s = sampleBSDF(in_dir, n, SHEEN[0], 1, 1, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF w = sampleBSDF(in_dir, n, SHEEN[1], 1, 1, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF c = connectBSDF(in_dir, w.unit_direction, n, SHEEN[1], 1, 1, w.lobe, hash(i));
            alone += s.throughput.x / (1 << 18), over += w.throughput.x / (1 << 18);
            alone2 += s.throughput.x * s.throughput.x / (1 << 18), over2 += w.throughput.x * w.throughput.x / (1 << 18);
            if (w.pdf > 0)
                worst = fmax(worst, fmax(fabs(c.pdf / w.pdf - 1), fabs(c.throughput.x / w.throughput.x - 1)));
        }
        // 4 standard errors of the sampled means
        const double se = 4 * sqrt(fmax(alone2 - alone * alone, 0) / (1 << 18)) + 0.002,
            over_se = 4 * sqrt(fmax(over2 - over * over, 0) / (1 << 18)) + 0.002;
        printf("sheen %g at cosine %g: alone %.4f of %.4f, over white %.4f of %.4f, worst mismatch %.2g\n", r, mu,
            alone, albedo, over, white, worst);
        failed |= fabs(alone - albedo) > se || fabs(over - white) > over_se || white > 1.002 || white < 0.99
            || worst > 1e-5;
    }
    // White velvet: alone its albedo E, over a white diffuse at most what it receives, sampled as connected and
    // evaluated, f(l, v) = f(v, l)
    const float VELVET_ROUGHNESSES[] = {0.1f, 0.3f, 0.6f, 1};
    for (const float r : VELVET_ROUGHNESSES) for (const float mu : VIEWS) {
        const Vector<float, 3> in_dir(sqrtf(1 - mu * mu), 0, -mu), v(-in_dir.x, 0, mu);
        const Material VELVET[] = {{ZERO, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ZERO, ONE, r, 0, 0, ZERO, 1},
            {ONE, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ZERO, ONE, r, 0, 0, ZERO, 1}};
        // By quadrature as for the sheen; f(l, v) = f(v, l) where neither view's table exceeds 1
        double albedo = 0, white = 0, alone = 0, over = 0, worst = 0, asymmetry = 0, alone2 = 0, over2 = 0;
        for (int i = 0; i < 512; i++) for (int j = 0; j < 1024; j++) {
            const float t = (i + 0.5f) / 512 * PI / 2, phi = (j + 0.5f) / 1024 * 2 * PI;
            const Vector<float, 3> l(sinf(t) * cosf(phi), sinf(t) * sinf(phi), cosf(t));
            const float f = BSDF(in_dir, l, n, n, VELVET[0], 1, 1, 0).x / cosf(t);
            const float g = BSDF(-l, v, n, n, VELVET[0], 1, 1, 0).x / mu;
            albedo += f * cosf(t) * sinf(t) * (PI / 2 / 512) * (2 * PI / 1024);
            white += BSDF(in_dir, l, n, n, VELVET[1], 1, 1, 0).x * sinf(t) * (PI / 2 / 512) * (2 * PI / 1024);
            asymmetry = fmax(asymmetry, fabs(f - g) / fmax(f, 1e-3));
        }
        for (unsigned i = 0; i < 1u << 18; i++) {
            const SampleBSDF s = sampleBSDF(in_dir, n, VELVET[0], 1, 1, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF w = sampleBSDF(in_dir, n, VELVET[1], 1, 1, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF c = connectBSDF(in_dir, w.unit_direction, n, VELVET[1], 1, 1, w.lobe, hash(i));
            alone += s.throughput.x / (1 << 18), over += w.throughput.x / (1 << 18);
            alone2 += s.throughput.x * s.throughput.x / (1 << 18), over2 += w.throughput.x * w.throughput.x / (1 << 18);
            if (w.pdf > 0)
                worst = fmax(worst, fmax(fabs(c.pdf / w.pdf - 1), fabs(c.throughput.x / w.throughput.x - 1)));
        }
        // 4 standard errors of the sampled means
        const double se = 4 * sqrt(fmax(alone2 - alone * alone, 0) / (1 << 18)) + 0.002,
            over_se = 4 * sqrt(fmax(over2 - over * over, 0) / (1 << 18)) + 0.002;
        printf("velvet %g at cosine %g: alone %.4f of %.4f, over white %.4f of %.4f, worst mismatch %.2g, asymmetry "
            "%.2g\n", r, mu, alone, albedo, over, white, worst, asymmetry);
        failed |= fabs(alone - albedo) > se || fabs(over - white) > over_se || white > 1.0001 || worst > 1e-5
            || asymmetry > 1e-3;
    }
    // Velvet's mean albedo over rings of view cosine and over the hemisphere, 2 * integral E(mu) * mu dmu, by midpoint
    // quadrature, against Blender's closure integrated apart
    const double RINGS[][4] = {{0.00011, 0.07940, 0.41787, 0.07998}, {0.03423, 0.36729, 0.69332, 0.24830},
        {0.22433, 0.60383, 0.82573, 0.45903}};
    const float RING_SIGMAS[] = {0.3f, 0.6f, 1};
    for (int k = 0; k < 3; k++) {
        double ring[3] = {}, weight[3] = {}, hemisphere = 0, off = 0;
        for (int m = 0; m < 64; m++) {
            const float mu = (m + 0.5f) / 64;
            const Vector<float, 3> v(sqrtf(1 - mu * mu), 0, mu);
            double e = 0;
            for (int i = 0; i < 256; i++) for (int j = 0; j < 512; j++) {
                const float t = (i + 0.5f) / 256 * PI / 2, phi = (j + 0.5f) / 512 * 2 * PI;
                const Vector<float, 3> l(sinf(t) * cosf(phi), sinf(t) * sinf(phi), cosf(t));
                const Material velvet = {ZERO, ZERO, 1, 0, 0, 1, ZERO, ONE, 1, ZERO, ONE, RING_SIGMAS[k], 0, 0, ZERO,
                    1};
                e += BSDF(-v, l, n, n, velvet, 1, 1, 0).x * sinf(t) * (PI / 2 / 256) * (2 * PI / 512);
            }
            hemisphere += 2 * e * mu / 64;
            const float LOW[] = {0.9f, 0.4f, 0.15f}, HIGH[] = {1, 0.6f, 0.3f};
            for (int q = 0; q < 3; q++) if (mu > LOW[q] && mu <= HIGH[q]) ring[q] += e * mu, weight[q] += mu;
        }
        for (int q = 0; q < 3; q++) off = fmax(off, fabs(ring[q] / weight[q] - RINGS[k][q]));
        off = fmax(off, fabs(hemisphere - RINGS[k][3]));
        printf("velvet %g rings %.5f %.5f %.5f, hemisphere %.5f, off by %.2g\n", RING_SIGMAS[k], ring[0] / weight[0],
            ring[1] / weight[1], ring[2] / weight[2], hemisphere, off);
        failed |= off > 1e-3;
    }
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
    const float ALPHAS[][2] = {{0.5f, 0.1f}, {0.1f, 0.5f}, {0.3f, 0.3f}, {0.05f, 0.4f}};
    for (const auto &a : ALPHAS) {
        const Vector<float, 2> alphas(a[0], a[1]);
        double d = 0, visible[6] = {};
        for (int i = 0; i < 2048; i++) for (int j = 0; j < 1024; j++) {
            const float t = (i + 0.5f) / 2048 * PI / 2, phi = (j + 0.5f) / 1024 * 2 * PI;
            const Vector<float, 3> h(sinf(t) * cosf(phi), sinf(t) * sinf(phi), cosf(t));
            const double D = anisotropicD(h, alphas) * sinf(t) * (PI / 2 / 2048) * (2 * PI / 1024);
            d += D * h.z;
            for (int k = 0; k < 6; k++) {
                const float s = sqrtf(1 - COSINES[k / 2] * COSINES[k / 2]);
                const Vector<float, 3> v(k % 2 ? 0 : s, k % 2 ? s : 0, COSINES[k / 2]);
                visible[k] += anisotropicG1(v, alphas) * fmax(dot(v, h), 0) * D / v.z;
            }
        }
        printf("anisotropic %g %g: D %.5f, visible normals %.5f %.5f %.5f %.5f %.5f %.5f\n", a[0], a[1], d, visible[0],
            visible[1], visible[2], visible[3], visible[4], visible[5]);
        failed |= fabs(d - 1) > 1e-3;
        for (const double x : visible) failed |= fabs(x - 1) > 1e-3;
    }
    const Vector<float, 3> X(1, 0, 0), COLORS[] = {RED, Vector<float, 3>(0, 0, 1)};
    const float ANISOTROPIES[] = {0.8f, -0.5f, 0.8f}, ROUGHNESS = 0.5f, ALPHA = ROUGHNESS * ROUGHNESS;
    const auto stretched = [&](int m, Vector<float, 3> albedo) {
        return Material{albedo, ZERO, ROUGHNESS, float(m < 2), float(m == 2), 1.5f, ZERO, ONE, 1, ZERO, ZERO, 0.5f, ANISOTROPIES[m], 0.1f, X};
    };
    const auto unit = [&](Vector<float, 3> a) { const float l = sqrtf(dot(a, a)); return Vector<float, 3>(a.x / l, a.y / l, a.z / l); };
    const Vector<float, 3> T(cosf(0.2f * PI), sinf(0.2f * PI), 0), B(-T.y, T.x, 0);
    for (int m = 0; m < 3; m++) for (int k = 0; k < 6; k++) {
        const Material M = stretched(m, ONE);
        const float aspect = sqrtf(1 - 0.9f * fabsf(ANISOTROPIES[m])), ax = ANISOTROPIES[m] < 0 ? ALPHA * aspect : ALPHA / aspect,
            ay = ALPHA * ALPHA / ax, sine = sqrtf(1 - COSINES[k / 2] * COSINES[k / 2]);
        const auto D = [&](Vector<float, 3> h) { const float x = dot(h, T) / ax, y = dot(h, B) / ay; return 1 / (PI * ax * ay * powf(x * x + y * y + h.z * h.z, 2)); };
        const auto G1 = [&](Vector<float, 3> w) { return 2 * w.z / (w.z + sqrtf(powf(ax * dot(w, T), 2) + powf(ay * dot(w, B), 2) + w.z * w.z)); };
        const Vector<float, 3> in_dir(k % 2 ? 0 : sine, k % 2 ? sine : 0, -COSINES[k / 2]), v(-in_dir.x, -in_dir.y, -in_dir.z);
        double albedo = 0, sum = 0, squares = 0, colored[2][3] = {}, worst = 0;
        for (int i = 0; i < 1024; i++) for (int j = 0; j < 1024; j++) {
            const float t = (i + 0.5f) / 1024 * PI, phi = (j + 0.5f) / 1024 * 2 * PI;
            const Vector<float, 3> l(sinf(t) * cosf(phi), sinf(t) * sinf(phi), cosf(t));
            albedo += BSDF(in_dir, l, n, n, M, 1, 1.5f, 0u).x * sinf(t) * (PI / 1024) * (2 * PI / 1024);
        }
        for (unsigned i = 0; i < 1u << 18; i++) {
            const SampleBSDF s = sampleBSDF(in_dir, n, M, 1, 1.5f, hash(i), Vector<float, 2>(0, 0));
            const SampleBSDF c = connectBSDF(in_dir, s.unit_direction, n, M, 1, 1.5f, s.lobe, hash(i));
            const Vector<float, 3> l = s.unit_direction;
            const float f = BSDF(in_dir, l, n, n, M, 1, 1.5f, hash(i)).x;
            sum += s.throughput.x / (1 << 18), squares += s.throughput.x * s.throughput.x / (1 << 18);
            if (s.pdf > 0 && s.throughput.x > 0) worst = fmax(worst, fmax(fabs(c.pdf / s.pdf - 1), fabs(f / (s.throughput.x * s.pdf) - 1)));
            if (m < 2 && s.throughput.x > 0) worst = fmax(worst, fmax(fabs(f / (D(unit(v + l)) * G1(v) * G1(l) / (4 * v.z)) - 1),
                fabs(f / l.z / (BSDF(Vector<float, 3>(-l.x, -l.y, -l.z), v, n, n, M, 1, 1.5f, 0u).x / v.z) - 1)));
            for (int r = 0; m < 2 && r < 2; r++) {
                const Vector<float, 3> t = sampleBSDF(in_dir, n, stretched(m, COLORS[r]), 1, 1.5f, hash(i), Vector<float, 2>(0, 0)).throughput;
                colored[r][0] += t.x / (1 << 18), colored[r][1] += t.y / (1 << 18), colored[r][2] += t.z / (1 << 18);
            }
        }
        const double error = 3 * sqrt(fmax(squares - sum * sum, 0) / (1 << 18));
        bool bad = albedo > 1 || fabs(sum - albedo) > error || worst > 1e-4;
        for (int r = 0; m < 2 && r < 2; r++) {
            const double color[3] = {COLORS[r].x, COLORS[r].y, COLORS[r].z};
            for (int ch = 0; ch < 3; ch++) bad |= colored[r][ch] > 1 || fabs(colored[r][ch] - albedo * color[ch]) > error;
        }
        printf("anisotropic %s %g along %c at cosine %g: albedo %.4f, sampled %.4f +- %.4f", m < 2 ? "metal" : "glass",
            ANISOTROPIES[m], k % 2 ? 'y' : 'x', COSINES[k / 2], albedo, sum, error);
        if (m < 2) printf(", red %.4f, blue %.4f", colored[0][0], colored[1][2]);
        printf(", worst mismatch %.2g%s\n", worst, bad ? " FAILED" : "");
        failed |= bad;
    }
    const Vector<float, 3> oblique(0.866f * cosf(0.3f), 0.866f * sinf(0.3f), -0.5f);
    Material isotropic = stretched(2, ONE), near = isotropic;
    isotropic.anisotropy = 0, near.anisotropy = 1e-6f;
    double limit = 0;
    for (unsigned i = 0; i < 4096; i++) {
        const SampleBSDF s = sampleBSDF(oblique, n, isotropic, 1, 1.5f, hash(i), Vector<float, 2>(0, 0));
        const SampleBSDF c = connectBSDF(oblique, s.unit_direction, n, near, 1, 1.5f, s.lobe, hash(i));
        const SampleBSDF e = connectBSDF(oblique, s.unit_direction, n, isotropic, 1, 1.5f, s.lobe, hash(i));
        if (e.pdf > 0 && e.throughput.x > 0) limit = fmax(limit, fmax(fabs(c.pdf / e.pdf - 1), fabs(c.throughput.x / e.throughput.x - 1)));
    }
    printf("anisotropic glass toward isotropic: worst mismatch %.2g\n", limit);
    failed |= limit > 1e-4;
    near.anisotropy = 0.8f, near.tangent = n;
    const SampleBSDF along = sampleBSDF(oblique, n, near, 1, 1.5f, hash(0), Vector<float, 2>(0, 0));
    printf("anisotropic glass of a tangent along the normal: %g\n", along.throughput.x * along.pdf);
    failed |= !isfinite(along.throughput.x * along.pdf);
    for (int m = 1; m < 3; m++) {
        const Material M = stretched(m, ONE);
        double share[64] = {}, worst_bin = 0;
        for (unsigned i = 0; i < 1u << 22; i++)
            share[bin(sampleBSDF(oblique, n, M, 1, 1.5f, hash(i), Vector<float, 2>(0, 0)).unit_direction)] += 1.0 / (1 << 22);
        for (int b = 0; b < 64; b++) {
            double expect = 0;
            for (unsigned j = 0; j < 4096; j++) {
                const float z = (b / 8 + (j % 64 + 0.5f) / 64) / 4 - 1, phi = (b % 8 + (j / 64 + 0.5f) / 64) / 8 * 2 * PI - PI;
                const Vector<float, 3> d(sqrtf(1 - z * z) * cosf(phi), sqrtf(1 - z * z) * sinf(phi), z);
                for (unsigned lobe = 1; lobe < 3; lobe++) expect += connectBSDF(oblique, d, n, M, 1, 1.5f, lobe, hash(j)).pdf * PI / 16 / 4096;
            }
            worst_bin = fmax(worst_bin, fabs(share[b] - expect) / (0.0005 + sqrt(expect / (1 << 22))));
        }
        printf("anisotropic %s density: worst bin off by %.2f of the tolerance\n", m < 2 ? "metal" : "glass", worst_bin);
        failed |= worst_bin > 1;
    }
    const Vector<float, 3> FIBERS[] = {Vector<float, 3>(0, 1, 0), Vector<float, 3>(0.6f, 0, 0.8f), unit(Vector<float, 3>(-0.3f, 0.5f, 0.2f))};
    const float SIDES[] = {1, -1}, ROWS[] = {64, 192, 128};
    float hair_miss = 0;
    for (const Vector<float, 3>& t : FIBERS) for (int k = 0; k < 3; k++) {
        const Vector<float, 3> in_dir = k < 2 ? Vector<float, 3>(t.x * SIDES[k], t.y * SIDES[k], t.z * SIDES[k]) : oblique;
        const Vector<float, 3> d = hairDirection(in_dir, t, 0, ROWS[k], 170, 0.3f, 0, 256, 512);
        const float miss = fabs(hairRow(in_dir, t, d, 0, 0.3f, 0, 256) - ROWS[k]) + fabs(hairColumn(in_dir, t, d, 512) - 170) + 0 * hairColumn(oblique, t, in_dir, 512);
        hair_miss = miss > hair_miss || miss != miss ? miss : hair_miss;
    }
    printf("hair along the fiber: worst row and column miss %g\n", hair_miss);
    failed |= !(hair_miss < 0.01f);
    failed |= !(fabsf(asinf(hairDirection(Vector<float, 3>(-1, 0, 0), Vector<float, 3>(0, 0, 1), 0, 128, 170, 0.05f, 0.035f, 256, 512).z) + 0.0704f) < 0.001f);
    failed |= hairRow(oblique, FIBERS[2], FIBERS[1], 5, 0.3f, 0.035f, 256) != hairRow(oblique, FIBERS[2], FIBERS[1], 1, 0.3f, 0.035f, 256);
    return failed;
}
