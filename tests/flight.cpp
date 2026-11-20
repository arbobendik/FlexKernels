#include <stdio.h>
#include <math.h>
#include <initializer_list>
#include "pathtracer.cpp"

int main() {
    using V = Vector<float, 3>;
    const V scatter(0.3f, 0.5f, 0.7f), extinction(0.8f, 0.9f, 1.4f);
    const float d = 1.7f;
    const int N = 1 << 22;
    double pass[3] = {0, 0, 0}, pass2[3] = {0, 0, 0}, first[3] = {0, 0, 0}, first2[3] = {0, 0, 0};
    double z1 = 0, z2 = 0, z4 = 0;
    for (int i = 0; i < N; i++) {
        // Free flight: E[unscattered] = exp(-e * d), E[first scattered] = s * (1 - exp(-e * d)) / e
        const float u = 3 * pcg(hash(2 * i + 1)).value;
        const int k = u < 1 ? 0 : u < 2 ? 1 : 2;
        const float t = - logf(1.0f - (u - k)) / (k == 0 ? scatter.x : k == 1 ? scatter.y : scatter.z);
        const V w = flightWeight_0(scatter, extinction, t < d ? t : d, t < d);
        const double c[3] = {w.x, w.y, w.z};
        for (int k = 0; k < 3; k++) {
            const double p = t < d ? 0 : c[k], f = t < d ? c[k] : 0;
            pass[k] += p, pass2[k] += p * p, first[k] += f, first2[k] += f * f;
        }
        // Isotropic: E[z] = 0, E[z^2] = 1 / 3
        float density;
        const V dir = samplePhase_0(0, V(0, 0, 1), hash(2 * i + 2), &density);
        z1 += dir.z, z2 += dir.z * dir.z, z4 += dir.z * dir.z * dir.z * dir.z;
    }
    const double s[3] = {scatter.x, scatter.y, scatter.z}, e[3] = {extinction.x, extinction.y, extinction.z};
    int failed = 0;
    for (int k = 0; k < 3; k++) {
        const double tp = exp(-e[k] * d), tf = s[k] * (1 - exp(-e[k] * d)) / e[k];
        const double mp = pass[k] / N, mf = first[k] / N;
        const double sp = sqrt((pass2[k] / N - mp * mp) / N), sf = sqrt((first2[k] / N - mf * mf) / N);
        const bool ok = fabs(mp - tp) < 4 * sp && fabs(mf - tf) < 4 * sf;
        failed += !ok;
        printf("channel %d: unscattered %.5f +- %.5f of %.5f, first scattered %.5f +- %.5f of %.5f%s\n", k, mp, sp, tp,
            mf, sf, tf, ok ? "" : "  FAILED");
    }
    const double mz = z1 / N, mz2 = z2 / N, sz = sqrt(1.0 / 3 / N), sz2 = sqrt((z4 / N - mz2 * mz2) / N);
    const bool iso = fabs(mz) < 4 * sz && fabs(mz2 - 1.0 / 3) < 4 * sz2;
    failed += !iso;
    printf("isotropic: z mean %.5f +- %.5f, z^2 mean %.5f +- %.5f of 0.33333%s\n", mz, sz, mz2, sz2,
        iso ? "" : "  FAILED");
    // Henyey-Greenstein: 2 * PI * integral_-1^1 p(mu) dmu = 1, PDF = p(mu), E[mu] = g
    for (const float g : {-0.9f, -0.3f, 0.3f, 0.9f}) {
        const int M = 1 << 16, K = 1 << 20;
        double integral = 0, mu1 = 0, mu2 = 0;
        for (int j = 0; j < M; j++)
            integral += 2 * 3.14159265358979 * phaseHG_0(g, -1 + (j + 0.5f) * 2.0f / M) * 2.0 / M;
        int misfits = 0;
        const V axis = normalize_0(V(0.3f, -0.4f, 0.8f));
        for (int i = 0; i < K; i++) {
            float density;
            const V dir = samplePhase_0(g, axis, hash(i), &density);
            const float mu = dot_0(dir, axis);
            misfits += fabsf(density - phaseHG_0(g, mu)) > 1e-3f * density;
            mu1 += mu, mu2 += double(mu) * mu;
        }
        const double mean = mu1 / K, se = sqrt((mu2 / K - mean * mean) / K);
        const bool ok = fabs(integral - 1) < 1e-4 && misfits == 0 && fabs(mean - g) < 4 * se;
        failed += !ok;
        printf("Henyey-Greenstein g %.1f: integral %.6f of 1, mean mu %.5f +- %.5f of %.1f, %d densities off%s\n", g,
            integral, mean, se, g, misfits, ok ? "" : "  FAILED");
    }
    return failed;
}
