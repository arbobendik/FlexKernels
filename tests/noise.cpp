#include <stdio.h>
#include <stdint.h>
#include <vector>
#include <algorithm>

// The tensor the generation's pass writes: S x S x NOISE_LAYERS texels, two ranks each as channel 0 | channel 1 << 16
static const uint32_t S = 64, T = 32;
static std::vector<uint32_t> tensor(S * S * T);
#include <noise.cpp>

// Each layer's ranks of channel c, sorted
static std::vector<uint32_t> layers(int c) {
    std::vector<uint32_t> sorted(tensor.size());
    for (size_t i = 0; i < tensor.size(); i++) sorted[i] = tensor[i] >> (16 * c) & 0xFFFF;
    for (uint32_t t = 0; t < T; t++) std::sort(sorted.begin() + t * S * S, sorted.begin() + (t + 1) * S * S);
    return sorted;
}

int main() {
    for (uint32_t t = 0; t < T; t++) for (uint32_t y = 0; y < S; y++) for (uint32_t x = 0; x < S; x++)
        tensor[(t * S + y) * S + x] = noiseWhite(x, y, t, S);
    const std::vector<uint32_t> start[2] = {layers(0), layers(1)};
    bool distinct = true;
    for (int c = 0; c < 2; c++) for (uint32_t i = 0; i < S * S * T; i++)
        distinct &= start[c][i] == i % (S * S) * (65536 / (S * S));
    // No texel reads as unbound, 0xFFFFFFFF
    for (uint32_t i = 0; i < S * S * T; i++) distinct &= tensor[i] != 0xFFFFFFFFu;
    printf("blue noise %ux%ux%u: start a permutation of every layer's channels %s%s\n", S, S, T,
        distinct ? "yes" : "NO", distinct ? "" : "  FAILED");
    return !distinct;
}
