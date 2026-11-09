// flex-cuda-pt's ray cones in the walk: a bounce widens the cone's spread by the angle of the solid angle its lobe's
// density spans, 2 sqrt(1 / (pi pdf)), up to pi all around, and delta lobes keep it, as renderer.cu's walk (66d4e7e,
// line 1522) reads, over densities from 1e-6 to 1e6 per steradian. Printed: the worst difference against that formula
// and the spreads at a Lambertian lobe's peak (2), a density past all around (pi) and a delta lobe (unchanged)
#include <stdio.h>
#include <math.h>
#include "pathtracer.cpp"

int main() {
    const float PI_F = 3.14159265f;
    double worst = 0;
    for (int i = 0; i <= 1200; i++) {
        const float pdf = powf(10.0f, -6.0f + i / 100.0f), spread = 0.25f * (i % 7);
        const float fcpt = spread + fminf(2 * sqrtf(1 / (PI_F * pdf)), PI_F);
        worst = fmax(worst, fabs(widened_0(spread, pdf, false) - fcpt) / fcpt);
        worst = fmax(worst, fabs(widened_0(spread, pdf, true) - spread));
    }
    const float lambert = widened_0(0, 1 / PI_F, false), around = widened_0(0, 1e-6f, false);
    const float delta = widened_0(0.5f, 1e6f, true);
    const bool ok = worst < 1e-6 && fabsf(lambert - 2) < 1e-5f && around == PI_F && delta == 0.5f;
    printf("cone spread: worst relative difference %.2e, Lambertian peak %.6f, past all around %.6f, delta %.6f%s\n",
        worst, lambert, around, delta, ok ? "" : "  FAILED");
    return !ok;
}
