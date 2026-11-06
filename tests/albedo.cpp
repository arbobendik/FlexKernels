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
#include <initializer_list>
#include <stdio.h>
#include "pathtracer.cpp"

// Fresnel's reflectance of a dielectric of IOR eta from outside at cosine c, unpolarized
static double hairFresnelReference(double c, double eta) {
    const double s2 = (1 - c * c) / (eta * eta);
    if (s2 >= 1) return 1;
    const double t = sqrt(1 - s2), rs = (c - eta * t) / (c + eta * t), rp = (eta * c - t) / (eta * c + t);
    return (rs * rs + rp * rp) / 2;
}

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
    // Anisotropic GGX of roughnesses along tangent and bitangent: D, and its visible normal density at views of cosines
    // 1, 0.5 and 0.2 along either, normalized by midpoint quadrature over the half vectors' hemisphere
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
    // A white metal of roughness 0.5 and anisotropy 0.8 or -0.5, and white glass of the first, turned by 0.1 about the
    // normal from a tangent along x, seen at those cosines along x and y: sampling returns the BSDF's albedo by midpoint
    // quadrature over the sphere, at most 1, to 3 standard errors, the metals red and blue per channel likewise; each
    // sample carrying light with the density and throughput connectBSDF and BSDF give it, the metals' BSDF reciprocal and
    // Torrance-Sparrow's of the roughnesses Blender's Principled mapping gives along the tangent turned
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
    // Toward anisotropy 0 the glass's lobes become the isotropic ones; and the density of the second metal's and the
    // glass's sampling, seen at cosine 0.5 between the axes, in the 64 bins of equal solid angle above: the share of
    // samples is the density of connectBSDF's lobes integrated over the bin
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
    // At the pole of Blender's radial tangent, where it lies along the normal, the glass still has a frame
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
            for (unsigned j = 0; j < 4096; j++) {  // Uniform points of the bin
                const float z = (b / 8 + (j % 64 + 0.5f) / 64) / 4 - 1, phi = (b % 8 + (j / 64 + 0.5f) / 64) / 8 * 2 * PI - PI;
                const Vector<float, 3> d(sqrtf(1 - z * z) * cosf(phi), sqrtf(1 - z * z) * sinf(phi), z);
                for (unsigned lobe = 1; lobe < 3; lobe++) expect += connectBSDF(oblique, d, n, M, 1, 1.5f, lobe, hash(j)).pdf * PI / 16 / 4096;
            }
            worst_bin = fmax(worst_bin, fabs(share[b] - expect) / (0.0005 + sqrt(expect / (1 << 22))));
        }
        printf("anisotropic %s density: worst bin off by %.2f of the tolerance\n", m < 2 ? "metal" : "glass", worst_bin);
        failed |= worst_bin > 1;
    }
    // Chiang's hair: a fiber absorbing nothing scatters all it receives at every h across it. Its BSDF times the cosine,
    // by midpoint quadrature over the sines of the longitude and the azimuth, integrates to 1, at roughnesses, radial
    // roughnesses, coats, IORs and the scales' tilt of Blender's range, seen at longitudes 0.3 and 1.2 off the normal
    // plane; sampling returns 1 likewise within 3 standard errors, each sample at the density and throughput the BSDF
    // gives it; and the share of samples in 64 bins of equal solid angle is the density integrated over the bin
    const float FIBERS[][5] = {{0.1f, 0.1f, 0, 1.55f, 0.035f}, {0.3f, 0.3f, 0, 1.55f, 0.035f}, {1, 1, 0, 1.55f, 0},
        {0.3f, 0.1f, 0, 1.55f, 0.035f}, {0.1f, 1, 0, 1.55f, 0.035f}, {0.3f, 0.3f, 0.5f, 1.55f, 0.035f}, {0.3f, 0.3f, 0, 2, 0.1f}};
    const float H[] = {-0.9f, -0.3f, 0.2f, 0.7f}, LONGITUDES[] = {0.3f, 1.2f};
    const Vector<float, 3> AXIS(1, 0, 0);
    for (const auto &f : FIBERS) for (const float longitude : LONGITUDES) {
        const Vector<float, 3> in_dir(-sinf(longitude), 0, -cosf(longitude));
        double worst = 0, sampled = 0, squares = 0, mismatch = 0;
        for (const float h : H) {
            const HairFiber fiber = hairFiber(ZERO, f[0], f[1], f[2], f[4], f[3], h);
            double sum = 0;
            for (int i = 0; i < 1024; i++) for (int j = 0; j < 1024; j++) {
                const float x = (i + 0.5f) / 512 - 1, phi = (j + 0.5f) / 1024 * 2 * PI, r = sqrtf(1 - x * x);
                float pdf;
                sum += hairBSDF(in_dir, Vector<float, 3>(x, r * cosf(phi), r * sinf(phi)), AXIS, fiber, &pdf).x * (2.0 / 1024) * (2 * PI / 1024);
            }
            worst = fmax(worst, fabs(sum - 1));
            for (unsigned i = 0; i < 1u << 16; i++) {
                const SampleBSDF s = sampleHair(in_dir, AXIS, fiber, hash(i));
                float pdf;
                const Vector<float, 3> value = hairBSDF(in_dir, s.unit_direction, AXIS, fiber, &pdf);
                sampled += s.throughput.x / (1 << 18), squares += s.throughput.x * s.throughput.x / (1 << 18);
                mismatch = fmax(mismatch, fmax(fabs(pdf / s.pdf - 1), fabs(value.x / (s.throughput.x * s.pdf) - 1)));
            }
        }
        const double error = 3 * sqrt(fmax(squares - sampled * sampled, 0) / (1 << 18));
        const bool bad = worst > 2e-4 || fabs(sampled - 1) > fmax(error, 1e-5) || mismatch > 1e-4;
        printf("hair %g %g coat %g IOR %g tilt %g at longitude %g: integral off 1 by %.2g, sampled %.4f +- %.4f, worst "
            "mismatch %.2g%s\n", f[0], f[1], f[2], f[3], f[4], longitude, worst, sampled, error, mismatch, bad ? " FAILED" : "");
        failed |= bad;
    }
    for (int k = 0; k < 2; k++) {
        const HairFiber fiber = hairFiber(Vector<float, 3>(0.2f, 0.4f, 0.8f), 0.3f, 0.3f, k ? 0.5f : 0, 0.035f, 1.55f, 0.4f);
        const Vector<float, 3> in_dir(-sinf(0.5f), 0, -cosf(0.5f));
        double share[64] = {}, worst_bin = 0;
        for (unsigned i = 0; i < 1u << 22; i++) share[bin(sampleHair(in_dir, AXIS, fiber, hash(i)).unit_direction)] += 1.0 / (1 << 22);
        for (int b = 0; b < 64; b++) {
            double expect = 0;
            for (unsigned j = 0; j < 4096; j++) {  // Uniform points of the bin
                const float z = (b / 8 + (j % 64 + 0.5f) / 64) / 4 - 1, phi = (b % 8 + (j / 64 + 0.5f) / 64) / 8 * 2 * PI - PI;
                float pdf;
                hairBSDF(in_dir, Vector<float, 3>(sqrtf(1 - z * z) * cosf(phi), sqrtf(1 - z * z) * sinf(phi), z), AXIS, fiber, &pdf);
                expect += pdf * PI / 16 / 4096;
            }
            worst_bin = fmax(worst_bin, fabs(share[b] - expect) / (0.0005 + sqrt(expect / (1 << 22))));
        }
        printf("hair density, coat %g: worst bin off by %.2f of the tolerance\n", k ? 0.5f : 0, worst_bin);
        failed |= worst_bin > 1;
    }
    // Against Chiang's model written out here in doubles from the angles, at 4096 random pairs of directions about a
    // tangent along x, of a tinted fiber of roughnesses 0.3 and 0.2, coat 0.5, tilt 0.06 and IOR 1.6 at five h: the
    // longitudinal Mp of d'Eon et al. by its integral, the azimuth's trimmed logistic shifted by 2 p gamma_t - 2 gamma_o
    // + p pi, the attenuation by Fresnel and Beer's law, the tilt turning theta_o by -2, 1 and 4 times the offset
    const auto variance = [](double r) { const double b = 0.726 * r + 0.812 * r * r + 3.7 * pow(r, 20); return b * b; };
    const auto mp = [](double ti, double to, double v) {  // Mp(theta_i, theta_o) by its integral over the azimuth
        double sum = 0;
        for (int k = 0; k < 4096; k++) {
            const double a = (k + 0.5) / 4096 * 2 * M_PI;
            sum += exp((cos(ti) * cos(to) * cos(a) - sin(ti) * sin(to)) / v);
        }
        return sum / 4096 / (2 * v * sinh(1 / v));
    };
    const double SIGMA[] = {0.3, 0.6, 1.2}, R = 0.3, RADIAL = 0.2, COAT = 0.5, TILT = 0.06, ETA = 1.6;
    const double s_ = (0.265 * RADIAL + 1.194 * RADIAL * RADIAL + 5.372 * pow(RADIAL, 22)) * sqrt(M_PI / 8);
    const double V[] = {variance(fmin(fmax((1 - COAT) * R, 0.001), 1)), variance(R) / 4, 4 * variance(R)};
    double reference_worst = 0;
    const float OFFSETS[] = {-0.8f, -0.4f, 0, 0.5f, 0.9f};
    for (const float h : OFFSETS) {
        const HairFiber fiber = hairFiber(Vector<float, 3>(SIGMA[0], SIGMA[1], SIGMA[2]), R, RADIAL, COAT, TILT, ETA, h);
        for (unsigned i = 0; i < 4096; i += 64) {
            const auto u = [&](unsigned k) { return (hash(i * 4 + k) >> 8) * 0x1p-24; };
            const double to = (u(0) - 0.5) * 2.8, po = u(1) * 2 * M_PI, ti = (u(2) - 0.5) * 2.8, pi = u(3) * 2 * M_PI;
            const Vector<float, 3> in_dir(-sin(to), -cos(to) * cos(po), -cos(to) * sin(po)), out_dir(sin(ti), cos(ti) * cos(pi), cos(ti) * sin(pi));
            float pdf;
            const Vector<float, 3> got = hairBSDF(in_dir, out_dir, AXIS, fiber, &pdf);
            const double go = asin(h), st_ = sin(to) / ETA, ct = sqrt(1 - st_ * st_), sgt = h / sqrt(ETA * ETA - sin(to) * sin(to)) * cos(to);
            const double gt = asin(sgt), fr = hairFresnelReference(cos(to) * cos(go), ETA), phi = pi - po;
            const double tilts[] = {-2 * TILT, TILT, 4 * TILT};
            double expect = 0;
            const double through = exp(-SIGMA[0] * 2 * cos(gt) / ct);
            double ap[4] = {fr, (1 - fr) * (1 - fr) * through, 0, 0};
            ap[2] = ap[1] * through * fr, ap[3] = ap[2] * through * fr / (1 - through * fr);
            for (int p = 0; p < 3; p++) {
                double d = phi - (2 * p * gt - 2 * go + p * M_PI);
                d -= 2 * M_PI * floor((d + M_PI) / (2 * M_PI));
                const double e = exp(-fabs(d) / s_), logistic = e / (s_ * (1 + e) * (1 + e)), trim = 1 - 2 / (1 + exp(M_PI / s_));
                expect += ap[p] * mp(ti, to - tilts[p], V[p]) * logistic / trim;
            }
            expect += ap[3] * mp(ti, to, 4 * variance(R)) / (2 * M_PI);
            reference_worst = fmax(reference_worst, fabs(got.x - expect) / (expect + 1e-3));
        }
    }
    printf("hair against Chiang written out: worst relative mismatch %.2g\n", reference_worst);
    failed |= reference_worst > 2e-3;
    // Where hairOffset puts a ray on the fiber, Chiang's R lobe, of a fiber absorbing all that enters it at roughness 0.05
    // without tilt, peaks at the ray's mirror image about the fiber's normal there, at normals from -1.2 to 1.2 off the
    // ray's opposite across the fiber
    double mirror_worst = 1;
    for (const float a : {-1.2f, -0.6f, 0.0f, 0.5f, 1.1f}) {
        const Vector<float, 3> ray(0, 0, -1), normal(0, sinf(a), cosf(a)), image(0, 2 * cosf(a) * sinf(a), -1 + 2 * cosf(a) * cosf(a));
        const HairFiber opaque = hairFiber(Vector<float, 3>(100, 100, 100), 0.05f, 0.05f, 0, 0, 1.55f, hairOffset(AXIS, normal, ray));
        float best = -1, cosine = 0;
        for (int j = 0; j < 8192; j++) {
            const float phi = (j + 0.5f) / 8192 * 2 * PI;
            const Vector<float, 3> d(0, cosf(phi), sinf(phi));
            float pdf;
            const float f = hairBSDF(ray, d, AXIS, opaque, &pdf).x;
            if (f > best) best = f, cosine = dot(d, image);
        }
        mirror_worst = fmin(mirror_worst, cosine);
    }
    printf("hair R lobe at the mirror image: worst cosine %.6f\n", mirror_worst);
    failed |= mirror_worst < 0.9999;
    // Blender's parametrizations (1 melanin, 2 colour, as HAIR_* in the source, whose constants Slang inlines): no
    // melanin and a white tint absorb nothing, eumelanin alone by its coefficients over -log(1 - melanin), and a colour by
    // Chiang's eq. 9 at the radial roughness, its polynomial written out here (the colour of a fiber assembly, not of
    // one fiber); a tint adds its colour's absorption to the melanin's; Random Color 0.5 at random 0.75 scales melanin
    // 0.5 by 1.25, and Random Roughness 0.5 there the roughnesses by 1.25
    const Vector<float, 3> none = hairSigma(1, ZERO, 0, 0.5f, ONE, ZERO, 0, 0.5f, 0.3f),
        dark = hairSigma(1, ZERO, 0.5f, 0, ONE, ZERO, 0, 0.5f, 0.3f),
        colour = hairSigma(2, Vector<float, 3>(0.5f, 0.25f, 0.1f), 0, 0, ONE, ZERO, 0, 0, 0.3f);
    const double eumelanin = -log(0.5), b = 0.3, scale = 5.969 - 0.215 * b + 2.532 * b * b - 10.73 * pow(b, 3) + 5.574 * pow(b, 4)
        + 0.245 * pow(b, 5);
    const double expect[] = {pow(log(0.5) / scale, 2), pow(log(0.25) / scale, 2), pow(log(0.1) / scale, 2)};
    const Vector<float, 3> tinted = hairSigma(1, ZERO, 0, 0, Vector<float, 3>(0.5f, 0.25f, 0.1f), ZERO, 0, 0.5f, 0.3f),
        randomized = hairSigma(1, ZERO, 0.5f, 0, ONE, ZERO, 0.5f, 0.75f, 0.3f);
    const float rough = hairRoughnessFactor(0.5f, 0.75f);
    printf("hair absorption: tinted %g %g %g, randomized eumelanin %g, roughness factor %g\n", tinted.x, tinted.y, tinted.z,
        randomized.x / 0.506, rough);
    failed |= fabs(tinted.x / expect[0] - 1) > 1e-5 || fabs(tinted.z / expect[2] - 1) > 1e-5
        || fabs(randomized.x / 0.506 + log(1 - 0.625)) > 1e-5 || fabs(rough - 1.25f) > 1e-6;
    printf("hair absorption: no melanin %g %g %g, eumelanin %g %g %g, colour %g %g %g of %g %g %g\n", none.x, none.y,
        none.z, dark.x / eumelanin, dark.y / eumelanin, dark.z / eumelanin, colour.x, colour.y, colour.z, expect[0], expect[1], expect[2]);
    failed |= none.x != 0 || none.y != 0 || none.z != 0 || fabs(dark.x / eumelanin - 0.506) > 1e-5
        || fabs(dark.z / eumelanin - 1.653) > 1e-5 || fabs(colour.x / expect[0] - 1) > 1e-5 || fabs(colour.z / expect[2] - 1) > 1e-5;
    return failed;
}
