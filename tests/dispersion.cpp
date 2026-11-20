// n(λ_d) = ior, (n_d - 1) / (n_F - n_C) = 1 / dispersion, integral w_c(λ) dλ = 1, integral p(λ) dλ = 1
// and E[w(λ) / p(λ)] = (1, 1, 1) for λ drawn by sampleWavelength
#include <stdio.h>
#include <math.h>
#include <initializer_list>
#include "pathtracer.cpp"
#include "terms.h"

int main() {
    const float D = 0.5875618f, F = 0.4861327f, C = 0.6562725f, IORS[] = {1.33f, 1.5168f, 2.42f};
    const float DISPERSIONS[] = {0, 1 / 64.17f, 1 / 20.0f};
    double at_d = 0, abbe = 0;
    for (float ior : IORS) for (float k : DISPERSIONS) {
        at_d = fmax(at_d, fabs(dispersedIor(ior, k, D) - ior));
        const float spread = dispersedIor(ior, k, F) - dispersedIor(ior, k, C);
        abbe = fmax(abbe, k > 0 ? fabs(spread / ((ior - 1) * k) - 1) : fabs(spread));
    }
    // N-BK7's catalogue n_F and n_C
    const float bk7_f = dispersedIor(1.5168f, 1 / 64.17f, F), bk7_c = dispersedIor(1.5168f, 1 / 64.17f, C);
    const bool lines = at_d < 1e-6 && abbe < 1e-4 && fabsf(bk7_f - 1.522376f) < 2e-4f
        && fabsf(bk7_c - 1.514322f) < 2e-4f;
    printf("dispersion: n(d) - ior at most %.1e, Abbe number off by %.1e, N-BK7 n_F %.5f n_C %.5f%s\n", at_d, abbe,
        bk7_f, bk7_c, lines ? "" : "  FAILED");
    const int STEPS = 400000;
    // The primaries' reflectances project to the unit colours, integral w_c(λ) upsample(e_k, λ) dλ = (c == k), in [0, 1]
    double white[3] = {}, projected[3][3] = {}, low = 0, high = 1;
    for (int i = 0; i < STEPS; i++) {
        const Vector<float, 3> w = wavelengthWeights(0.38f + 0.4f * (i + 0.5f) / STEPS);
        white[0] += w.x * 0.4 / STEPS, white[1] += w.y * 0.4 / STEPS, white[2] += w.z * 0.4 / STEPS;
        for (int k = 0; k < 3; k++) {
            const float r = upsample(Vector<float, 3>(k == 0, k == 1, k == 2), 0.38f + 0.4f * (i + 0.5f) / STEPS);
            low = fmin(low, r), high = fmax(high, r);
            projected[k][0] += w.x * r * 0.4 / STEPS, projected[k][1] += w.y * r * 0.4 / STEPS;
            projected[k][2] += w.z * r * 0.4 / STEPS;
        }
    }
    double trip = 0;
    for (int k = 0; k < 9; k++) trip = fmax(trip, fabs(projected[k / 3][k % 3] - (k / 3 == k % 3)));
    printf("primaries: projected off the unit colours by at most %.1e, reflectance from %.4f to %.4f%s\n", trip, low,
        high, trip < 2e-5 && low >= 0 && high <= 1 ? "" : "  FAILED");
    double density = 0, mean[3] = {}, least = 1, most = 0, previous = 0.38;
    for (int i = 0; i < STEPS; i++) {
        const Vector<float, 2> drawn = sampleWavelength((i + 0.5f) / STEPS);
        const Vector<float, 3> w = wavelengthWeights(drawn.x);
        density += drawn.y * (drawn.x - previous), previous = drawn.x;
        least = fmin(least, drawn.x), most = fmax(most, drawn.x);
        mean[0] += w.x / drawn.y / STEPS, mean[1] += w.y / drawn.y / STEPS, mean[2] += w.z / drawn.y / STEPS;
    }
    bool ok = lines && trip < 2e-5 && low >= 0 && high <= 1 && least >= 0.38 && most <= 0.78 && fabs(density - 1) < 1e-3;
    for (int c = 0; c < 3; c++) ok = ok && fabs(white[c] - 1) < 1e-4 && fabs(mean[c] - 1) < 1e-3;
    printf("wavelengths: integral of w (%.5f, %.5f, %.5f), of p %.5f over %.3f to %.3f um", white[0], white[1],
        white[2], density, least, most);
    printf(", E[w / p] (%.5f, %.5f, %.5f)%s\n", mean[0], mean[1], mean[2], ok ? "" : "  FAILED");
    // Prism of apex 60 degrees entered at its d line's minimum deviation through sampleBSDF's refraction at each λ:
    // per channel E[w_c / p δ] / E[w_c / p], against the integral of w_c δ over the interpolated weights
    struct Prism { float ior, dispersion, centroid[3]; };
    const Prism PRISMS[] = {{1.5f, 0.2f, {34.804f, 39.318f, 48.285f}}, {1.5f, 0.1f, {35.980f, 38.255f, 42.398f}},
        {1.5f, 0, {37.181f, 37.181f, 37.181f}}, {1.5168f, 1 / 64.17f, {38.450f, 38.822f, 39.466f}}};
    const float A = 3.14159265f / 3;
    const Vector<float, 3> n1(-cosf(A / 2), 0, sinf(A / 2)), n2(cosf(A / 2), 0, sinf(A / 2));
    const auto refracted = [](Vector<float, 3> d, Vector<float, 3> n, Material m, float wavelength) {
        Material refractive = m;
        refractive.ior = wavelength > 0 ? dispersedIor(m.ior, m.dispersion, wavelength) : m.ior;
        const Vector<float, 2> eta = vertexEta(refractive, dot_0(n, -d));
        for (unsigned k = 0; k < 64; k++) {
            const SampleBSDF s = sampleBSDF(d, n, m, eta.x, eta.y, hash(k), Vector<float, 2>(0, 0));
            if (s.lobe == 1) return s.unit_direction;
        }
        return Vector<float, 3>(0, 0, 0);
    };
    for (const Prism& prism : PRISMS) {
        Material glass = {Vector<float, 3>(1, 1, 1), Vector<float, 3>(0, 0, 0), 0, 0, 1, prism.ior,
            Vector<float, 3>(1, 1, 1), Vector<float, 3>(1, 1, 1), 1, Vector<float, 3>(0, 0, 0),
            Vector<float, 3>(0, 0, 0), 0.5f, 0, 0, Vector<float, 3>(0, 0, 0)};
        glass.dispersion = prism.dispersion;
        const float enter = asinf(prism.ior * sinf(A / 2));
        const Vector<float, 3> in_dir(cosf(A / 2) * cosf(enter) + sinf(A / 2) * sinf(enter), 0,
            -sinf(A / 2) * cosf(enter) + cosf(A / 2) * sinf(enter));
        double sum[3] = {}, weight[3] = {}, worst = 0;
        for (int i = 0; i < 1 << 16; i++) {
            const Vector<float, 2> drawn = sampleWavelength((i + 0.5f) / (1 << 16));
            const Vector<float, 3> out = refracted(refracted(in_dir, n1, glass, drawn.x), n2, glass, drawn.x);
            const double deviation = acos(fmin(1.0, dot_0(in_dir, out))) * 180 / M_PI;
            const Vector<float, 3> w = wavelengthWeights(drawn.x);
            const double c[3] = {w.x / drawn.y, w.y / drawn.y, w.z / drawn.y};
            for (int k = 0; k < 3; k++) sum[k] += c[k] * deviation, weight[k] += c[k];
        }
        for (int k = 0; k < 3; k++) worst = fmax(worst, fabs(sum[k] / weight[k] - prism.centroid[k]));
        ok = ok && worst < 0.01;
        printf("prism n_d %g, dispersion %g: deviation (%.3f, %.3f, %.3f) degrees, off by %.4f%s\n", prism.ior,
            prism.dispersion, sum[0] / weight[0], sum[1] / weight[1], sum[2] / weight[2], worst,
            worst < 0.01 ? "" : "  FAILED");
    }
    // Energy per wavelength: smooth glass reflects and refracts all, R + T = 1 at n(λ); rough glass keeps at most 1
    const float CUTS[] = {0.4f, 0.48f, 0.56f, 0.64f, 0.72f}, COSINES[] = {1, 0.5f, 0.2f};
    double smooth = 0, rough = 0;
    for (float wavelength : CUTS) for (float c : COSINES) for (float roughness : {0.0f, 0.3f}) {
        Material glass = {Vector<float, 3>(1, 1, 1), Vector<float, 3>(0, 0, 0), roughness, 0, 1, 1.5f,
            Vector<float, 3>(1, 1, 1), Vector<float, 3>(1, 1, 1), 1, Vector<float, 3>(0, 0, 0),
            Vector<float, 3>(0, 0, 0), 0.5f, 0, 0, Vector<float, 3>(0, 0, 0)};
        glass.dispersion = 0.2f;
        const Vector<float, 3> in_dir(sqrtf(1 - c * c), 0, -c), n(0, 0, 1);
        Material refractive = glass;
        refractive.ior = dispersedIor(glass.ior, glass.dispersion, wavelength);
        const Vector<float, 2> eta = vertexEta(refractive, c);
        double sum = 0;
        for (unsigned i = 0; i < 1u << 16; i++)
            sum += sampleBSDF(in_dir, n, glass, eta.x, eta.y, hash(i), Vector<float, 2>(0, 0)).throughput.x / (1 << 16);
        if (roughness == 0) smooth = fmax(smooth, fabs(sum - 1));
        else rough = fmax(rough, sum - 1);
    }
    const bool kept = smooth < 1e-5 && rough < 0.005;
    ok = ok && kept;
    printf("energy per wavelength: smooth glass off 1 by %.1e, rough glass at most %+.4f over 1%s\n", smooth, rough,
        kept ? "" : "  FAILED");
    return !ok;
}
