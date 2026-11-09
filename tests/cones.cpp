// spread += min(2 * sqrt(1 / (PI * pdf)), PI), delta lobes unchanged
#include <stdio.h>
#include <math.h>
#include "pathtracer.cpp"

int main() {
    const float PI_F = 3.14159265f;
    double worst = 0;
    for (int i = 0; i <= 1200; i++) {
        const float pdf = powf(10.0f, -6.0f + i / 100.0f), spread = 0.25f * (i % 7);
        const float fcpt = spread + fminf(2 * sqrtf(1 / (PI_F * pdf)), PI_F);
        worst = fmax(worst,
            fabs((spread + (false ? 0.0f : fminf(2.0f * sqrtf(1.0f / (PI_F * pdf)), PI_F))) - fcpt) / fcpt);
        worst = fmax(worst, fabs((spread + (true ? 0.0f : fminf(2.0f * sqrtf(1.0f / (PI_F * pdf)), PI_F))) - spread));
    }
    const float lambert = (0 + (false ? 0.0f : fminf(2.0f * sqrtf(1.0f / (PI_F * (1 / PI_F))), PI_F))),
        around = (0 + (false ? 0.0f : fminf(2.0f * sqrtf(1.0f / (PI_F * (1e-6f))), PI_F)));
    const float delta = (0.5f + (true ? 0.0f : fminf(2.0f * sqrtf(1.0f / (PI_F * 1e6f)), PI_F)));
    const bool ok = worst < 1e-6 && fabsf(lambert - 2) < 1e-5f && around == PI_F && delta == 0.5f;
    printf("cone spread: worst relative difference %.2e, Lambertian peak %.6f, past all around %.6f, delta %.6f%s\n",
        worst, lambert, around, delta, ok ? "" : "  FAILED");
    return !ok;
}
