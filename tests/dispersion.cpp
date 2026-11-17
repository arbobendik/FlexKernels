// n(λ_d) = ior, (n_d - 1) / (n_F - n_C) = 1 / dispersion, integral w_c(λ) dλ = 1, integral p(λ) dλ = 1
// and E[w(λ) / p(λ)] = (1, 1, 1) for λ drawn by sampleWavelength
#include <stdio.h>
#include <math.h>
#include "pathtracer.cpp"

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
    double white[3] = {};
    for (int i = 0; i < STEPS; i++) {
        const Vector<float, 3> w = wavelengthWeights(0.38f + 0.4f * (i + 0.5f) / STEPS);
        white[0] += w.x * 0.4 / STEPS, white[1] += w.y * 0.4 / STEPS, white[2] += w.z * 0.4 / STEPS;
    }
    double density = 0, mean[3] = {}, least = 1, most = 0, previous = 0.38;
    for (int i = 0; i < STEPS; i++) {
        const Vector<float, 2> drawn = sampleWavelength((i + 0.5f) / STEPS);
        const Vector<float, 3> w = wavelengthWeights(drawn.x);
        density += drawn.y * (drawn.x - previous), previous = drawn.x;
        least = fmin(least, drawn.x), most = fmax(most, drawn.x);
        mean[0] += w.x / drawn.y / STEPS, mean[1] += w.y / drawn.y / STEPS, mean[2] += w.z / drawn.y / STEPS;
    }
    bool ok = lines && least >= 0.38 && most <= 0.78 && fabs(density - 1) < 1e-3;
    for (int c = 0; c < 3; c++) ok = ok && fabs(white[c] - 1) < 1e-4 && fabs(mean[c] - 1) < 1e-3;
    printf("wavelengths: integral of w (%.5f, %.5f, %.5f), of p %.5f over %.3f to %.3f um", white[0], white[1],
        white[2], density, least, most);
    printf(", E[w / p] (%.5f, %.5f, %.5f)%s\n", mean[0], mean[1], mean[2], ok ? "" : "  FAILED");
    return !ok;
}
