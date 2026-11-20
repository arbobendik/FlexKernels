#include <stdio.h>
#include <stdint.h>
#include <math.h>
#include <vector>
#include <algorithm>

// The tensor the generation's passes write and the draws read: S x S x NOISE_LAYERS texels, two ranks each as
// channel 0 | channel 1 << 16
#define FK_BLUE_NOISE
static const uint32_t S = 64, T = 32;
static std::vector<uint32_t> tensor(S * S * T);
static uint32_t fkBlueNoise(uint32_t x, uint32_t y, uint32_t t) { return tensor[(t * S + y) * S + x]; }
static uint32_t fkBlueNoiseSize() { return S; }
#include <noise.cpp>

// Rank of channel c at texel (x, y) of layer t
static uint32_t rank(uint32_t x, uint32_t y, uint32_t t, int c) { return fkBlueNoise(x, y, t) >> (16 * c) & 0xFFFF; }

// Variance of channel c blurred by a Gaussian of sigma 2 within each layer (space) or along each pixel (time):
// low-frequency power, which blue noise lacks
static double blurred(bool space, int c) {
    double w[13], sum = 0;
    for (int d = -6; d <= 6; d++) sum += w[d + 6] = exp(-d * d / 8.0);
    double v = 0, v2 = 0;
    for (uint32_t t = 0; t < T; t++) for (uint32_t y = 0; y < S; y++) for (uint32_t x = 0; x < S; x++) {
        double b = 0;
        if (space) {
            for (int dy = -6; dy <= 6; dy++) for (int dx = -6; dx <= 6; dx++)
                b += w[dx + 6] * w[dy + 6] * rank((x + dx + S) % S, (y + dy + S) % S, t, c);
            b /= sum * sum;
        } else {
            for (int dt = -6; dt <= 6; dt++) b += w[dt + 6] * rank(x, y, (t + dt + T) % T, c);
            b /= sum;
        }
        v += b / 65536, v2 += b / 65536 * b / 65536;
    }
    const double n = double(S) * S * T;
    return v2 / n - v / n * (v / n);
}

// Each layer's ranks of channel c, sorted
static std::vector<uint32_t> layers(int c) {
    std::vector<uint32_t> sorted(tensor.size());
    for (size_t i = 0; i < tensor.size(); i++) sorted[i] = tensor[i] >> (16 * c) & 0xFFFF;
    for (uint32_t t = 0; t < T; t++) std::sort(sorted.begin() + t * S * S, sorted.begin() + (t + 1) * S * S);
    return sorted;
}

// Bounds above the 0.078 and 0.172 that 24 sweeps reach on the worse channel, far below white's 1
static const double SPACE_BOUND = 0.15, TIME_BOUND = 0.3;

int main() {
    RWStructuredBuffer<uint32_t> passes = {tensor.data(), tensor.size()};
    for (uint32_t t = 0; t < T; t++) for (uint32_t y = 0; y < S; y++) for (uint32_t x = 0; x < S; x++)
        tensor[(t * S + y) * S + x] = noiseWhite(x, y, t, S);
    const std::vector<uint32_t> start[2] = {layers(0), layers(1)};
    bool distinct = true;
    for (int c = 0; c < 2; c++) for (uint32_t i = 0; i < S * S * T; i++)
        distinct &= start[c][i] == i % (S * S) * (65536 / (S * S));
    // No texel reads as unbound, 0xFFFFFFFF
    for (uint32_t i = 0; i < S * S * T; i++) distinct &= tensor[i] != 0xFFFFFFFFu;
    const double white[4] = {blurred(true, 0), blurred(true, 1), blurred(false, 0), blurred(false, 1)};
    const int SWEEPS = 24;
    for (int sweep = 0; sweep < SWEEPS; sweep++) for (uint32_t colour = 0; colour < 8; colour++)
        for (uint32_t block = 0; block < (S / 16) * (S / 16) * (T / 16); block++)
            noiseSweepBlock_0(passes, sweep, colour, block, S);
    // The worse channel's low-frequency power against white's
    const double space = std::max(blurred(true, 0) / white[0], blurred(true, 1) / white[1]);
    const double time = std::max(blurred(false, 0) / white[2], blurred(false, 1) / white[3]);
    const bool uniform = layers(0) == start[0] && layers(1) == start[1];
    const bool ok = distinct && uniform && space < SPACE_BOUND && time < TIME_BOUND;
    printf("blue noise %ux%ux%u, %d sweeps: start a permutation of every layer's channels %s, the swaps keep each "
        "layer's ranks %s; low-frequency power against white, the worse channel, in space %.3f (< %.2f), in time %.3f "
        "(< %.2f)%s\n", S, S, T, SWEEPS,
        distinct ? "yes" : "NO", uniform ? "yes" : "NO", space, SPACE_BOUND, time, TIME_BOUND,
        ok ? "" : "  FAILED");
    return !ok;
}
