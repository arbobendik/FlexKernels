// With ReSTIR off, flex-cuda-pt's walk only sums a path's contributions into its selection (renderer.cu 1206-1211): a
// selection marked to sum adds each weight offered to its color and keeps neither a running weight nor a reservoir,
// degenerate weights still rejected; unmarked, it resamples as ReSTIR does. Printed: both selections after the offers
#include <stdio.h>
#include "pathtracer.cpp"

int main() {
    using V = Vector<float, 3>;
    const V weights[4] = {V(1, 2, 3), V(0.5f, 0.5f, 0.5f), V(-1, -1, -1), V(2, 0, 1)};
    Selection summed = {}, resampled = {};
    summed.sums = true, summed.random_state = resampled.random_state = 7;
    for (unsigned i = 0; i < 4; i++) {
        Reservoir candidate = {};
        candidate.seed = i + 1;
        offer(&summed, candidate, weights[i]);
        offer(&resampled, candidate, weights[i]);
    }
    const bool sums = summed.color.x == 3.5f && summed.color.y == 2.5f && summed.color.z == 4.5f
        && summed.w_sum == 0 && summed.r.seed == 0;
    const bool resamples = resampled.color.x == 3.5f && resampled.w_sum > 0 && resampled.r.seed != 0;
    printf("summing: color (%g, %g, %g), running weight %g, reservoir seed %u; resampling: running weight %g, "
        "reservoir seed %u%s\n", summed.color.x, summed.color.y, summed.color.z, summed.w_sum, summed.r.seed,
        resampled.w_sum, resampled.r.seed, sums && resamples ? "" : "  FAILED");
    return !(sums && resamples);
}
