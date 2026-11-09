// flex-cuda-pt's alpha coverage in the walk: the share of draws a surface leaves uncovered is one minus its coverage,
// within four standard errors; an uncovered surface passes rays straight through at full throughput, its emission and
// absorption kept, where the covered one bends or scatters them; and its draws are independent of the sky samples' at
// the same vertex, as flex-cuda-pt's coverage and FlexLight's sky streams both start at 256: the generated walk's
// offsets read from its code, their draws' correlation under 4 / sqrt(N), where the same stream for both reads 1.
// Printed: each reading against its must-fail control
#include <stdio.h>
#include <math.h>
#include "pathtracer.cpp"

#include <fstream>
#include <sstream>
#include <string>

// The stream offset the generated walk draws for the first call after uncovered's definition whose text follows: the
// last `stream(..., b + N)` before it, as the walk inlines STREAM_COVERAGE and STREAM_SKY; GENERATED, the code above
static uint32_t offsetBefore(const std::string& code, const char* call) {
    const size_t at = code.find(call, code.find("uncovered_0(Surface") + 1);
    const size_t draw = code.rfind("stream(", at), plus = code.find("+ ", draw);
    return at == std::string::npos ? 0 : uint32_t(std::stoul(code.substr(plus + 2)));
}

int main() {
    const Vector<float, 3> ONE(1, 1, 1), up(0, 0, 1), in(0.6f, 0, -0.8f);
    const Vector<float, 3> glow(0.5f, 0.25f, 0), absorb(0.9f, 0.8f, 0.7f);
    const Material WHITE = {ONE, glow, 1, 0, 0, 1, absorb, ONE, 1};
    const float COVERAGE = 0.3f;
    std::stringstream text;
    text << std::ifstream(GENERATED).rdbuf();
    const uint32_t STREAM_COVERAGE = offsetBefore(text.str(), "uncovered_0("), STREAM_SKY = offsetBefore(text.str(),
        "sampleSky_0(");
    Surface surface = {up, up, 1e-4f, WHITE, false, 0, COVERAGE};
    const int N = 1 << 20;
    int failed = 0;
    // Uncovered share, which the comparison reversed would read as the coverage
    double uncovered = 0, cc = 0, cs = 0, ss = 0, c1 = 0, s1 = 0, same = 0;
    for (int i = 0; i < N; i++) {
        const uint32_t seed = hash(i), b = i % 8;
        const float u = pcg(stream(seed, b + STREAM_COVERAGE)).value, v = pcg(stream(seed, b + STREAM_SKY)).value;
        const Surface s = uncovered_0(&surface, u);
        uncovered += s.material.transmission == 1 && s.material.ior == 1;
        c1 += u, s1 += v, cc += u * u, ss += v * v, cs += u * v;
        same += u == pcg(stream(seed, b + 256)).value;
    }
    const double share = uncovered / N, se = sqrt(COVERAGE * (1 - COVERAGE) / N);
    const bool share_ok = fabs(share - (1 - COVERAGE)) < 4 * se && fabs(share - COVERAGE) > 4 * se;
    const double corr = (cs / N - c1 / N * s1 / N) / sqrt((cc / N - c1 / N * c1 / N) * (ss / N - s1 / N * s1 / N));
    const bool streams_ok = fabs(corr) < 4 / sqrt(double(N)) && same == N;
    // Straight through at full throughput where uncovered, bent or scattered where covered, 37 degrees off the normal
    surface.coverage = 0;
    const Surface through = uncovered_0(&surface, 0.5f);
    // At the indices of refraction the walk takes from each material
    Material passing = through.material, covered = WHITE;
    const Vector<float, 2> eta = vertexEta_0(&passing, -in.z), eta_covered = vertexEta_0(&covered, -in.z);
    int straight = 0, bent = 0;
    for (int i = 0; i < 1024; i++) {
        const Vector<float, 2> NO_SCREEN(0, 0);
        const SampleBSDF t = sampleBSDF(in, up, passing, eta.x, eta.y, hash(2 * i + 1), NO_SCREEN);
        const SampleBSDF c = sampleBSDF(in, up, covered, eta_covered.x, eta_covered.y, hash(2 * i + 1), NO_SCREEN);
        straight += t.unit_direction.x * in.x + t.unit_direction.z * in.z > 0.99999f
            && fabsf(t.throughput.x - 1) < 1e-5f && fabsf(t.throughput.z - 1) < 1e-5f;
        bent += c.unit_direction.x * in.x + c.unit_direction.z * in.z > 0.99999f && fabsf(c.throughput.x - 1) < 1e-5f;
    }
    const bool kept = through.material.emissive.x == glow.x && through.material.emissive.y == glow.y
        && through.material.absorption.x == absorb.x && through.material.absorption.z == absorb.z;
    const bool pass_ok = straight == 1024 && bent == 0 && kept;
    failed += !share_ok + !streams_ok + !pass_ok;
    printf("uncovered share %.5f of %.5f +- %.5f (control, coverage %.5f), sky streams %u and %u: correlation %.5f "
        "(control, stream 256 for both: %.0f of %d equal), straight through %d of 1024 (control %d), emission and "
        "absorption %s%s\n", share, 1 - COVERAGE, se, COVERAGE, STREAM_COVERAGE, STREAM_SKY, corr, same, N, straight,
        bent, kept ? "kept" : "LOST", failed ? "  FAILED" : "");
    return failed;
}
