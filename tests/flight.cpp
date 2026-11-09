// flex-cuda-pt's free flight through a homogeneous medium in the walk: along a segment of length d of extinction e
// and scattering s (mean sigma), the walk's estimate of what passes unscattered reads exp(-e d), and of what first
// scatters, weighted by s, reads s (1 - exp(-e d)) / e, each per channel within four standard errors, as it samples
// distances at density sigma exp(-sigma t) and flightWeight divides it out (renderer.cu 66d4e7e, lines 1574-1583,
// 1643); and isotropic directions are uniform over the sphere, their z mean 0 and z^2 mean 1/3 within four standard
// errors. Printed: each reading against its closed form
#include <stdio.h>
#include <math.h>
#include "pathtracer.cpp"

int main() {
    using V = Vector<float, 3>;
    const V scatter(0.3f, 0.5f, 0.7f), extinction(0.8f, 0.9f, 1.4f);
    const float sigma = (scatter.x + scatter.y + scatter.z) / 3, d = 1.7f;
    const int N = 1 << 22;
    double pass[3] = {0, 0, 0}, pass2[3] = {0, 0, 0}, first[3] = {0, 0, 0}, first2[3] = {0, 0, 0};
    double z1 = 0, z2 = 0, z4 = 0;
    for (int i = 0; i < N; i++) {
        const float u = pcg(hash(2 * i + 1)).value, t = freeFlight_0(u, sigma);
        const V w = flightWeight_0(scatter, extinction, sigma, t < d ? t : d, t < d);
        const double c[3] = {w.x, w.y, w.z};
        for (int k = 0; k < 3; k++) {
            const double p = t < d ? 0 : c[k], f = t < d ? c[k] : 0;
            pass[k] += p, pass2[k] += p * p, first[k] += f, first2[k] += f * f;
        }
        const V dir = isotropic_0(hash(2 * i + 2));
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
    return failed;
}
