#include <stdio.h>
#include <algorithm>
#include <vector>
#include "pathtracer.cpp"

static const int W = 16, H = 8, BINS = 40;
static Reservoir temporal[W * H];
// Dispatch size, counts and cursors per bin, then the jobs
static uint32_t queue[3 + 2 * BINS + 3 * W * H];
static bool inside(Vector<int32_t, 2> p) { return p.x >= 0 && p.y >= 0 && p.x < W && p.y < H; }

Vector<uint32_t, 2> HookScene_renderSize_0() { return Vector<uint32_t, 2>(W, H); }
uint32_t HookScene_frame_0() { return 3; }
uint32_t HookScene_restirNeighbours_0() { return 3; }
Vector<int32_t, 4> HookScene_pairing_0(Vector<int32_t, 2> texel, uint32_t t) {
    return Vector<int32_t, 4>(int(t) + 1 - texel.x % 3, texel.y % 2 - 1, 0, 0);
}
Reservoir HookScene_loadReservoirTemporal_0(Vector<int32_t, 2> p) { return temporal[p.y * W + p.x]; }
// Partners off the image and in its last column have no domain
bool HookScene_storedDomainTemporal_0(Vector<int32_t, 2> q, Domain*) { return inside(q) && q.x != W - 1; }
uint32_t HookScene_queueCountAdd_0(uint32_t bin, uint32_t jobs) { return (queue[3 + bin] += jobs) - jobs; }
uint32_t HookScene_queueCountLoad_0(uint32_t bin) { return queue[3 + bin]; }
uint32_t HookScene_queueCursorAdd_0(uint32_t bin, uint32_t jobs) { return (queue[3 + BINS + bin] += jobs) - jobs; }
void HookScene_queueJobStore_0(uint32_t index, uint32_t job) { queue[3 + 2 * BINS + index] = job; }
void HookScene_queueDispatchStore_0(uint32_t x, uint32_t y, uint32_t z) { queue[0] = x, queue[1] = y, queue[2] = z; }
uint32_t HookScene_queuedShifts_0(uint32_t index) { return queue[index]; }
void HookScene_storeShiftData_0(Vector<int32_t, 2>, uint32_t, Vector<uint32_t, 4>) {}

int main() {
    int failed = 0;
    // Reservoirs of every reconnection type, end type and depth, every fifth empty
    for (int i = 0; i < W * H; i++) {
        temporal[i] = Reservoir{};
        temporal[i].w = i % 5 == 0 ? 0 : 1;
        temporal[i].path = (i % 8) << 5 | (i % 4) << 10 | (i % 7) << 12 | (i % 9);
    }
    // Spatial round: count, prepass, then the queue drained group by group
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
        restir_count_hook(Vector<uint32_t, 3>(x, y, 0), (y % 8) * 8 + x % 8);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
        restir_prepass_hook(Vector<uint32_t, 3>(x, y, 0), (y % 8) * 8 + x % 8);
    std::vector<uint32_t> run, expected;
    for (uint32_t group = 0; group < queue[0] * queue[1]; group++) for (uint32_t local = 0; local < 64; local++) {
        const uint32_t job = queuedShift_0(Vector<uint32_t, 3>(group % 65535, group / 65535, 0), local);
        if (job != 0xFFFFFFFFu) run.push_back(job);
    }
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (uint32_t t = 0; t < 3; t++) {
        ShiftJob job = {};
        if (spatialJob_0(Vector<int32_t, 2>(x, y), t, &job)) expected.push_back(x | y << 14 | t << 28);
    }
    std::vector<uint32_t> sorted = run;
    std::sort(sorted.begin(), sorted.end()), std::sort(expected.begin(), expected.end());
    const bool once = sorted == expected && !expected.empty();
    failed += !once;
    printf("spatial queue: %zu jobs run, %zu expected, each once%s\n", run.size(), expected.size(),
        once ? "" : "  FAILED");
    // Jobs run bin after bin
    uint32_t last = 0, unordered = 0;
    for (const uint32_t job : run) {
        Reservoir r = temporal[(job >> 14 & 16383) * W + (job & 16383)];
        const uint32_t bin = shiftBin_0(&r);
        unordered += bin < last, last = bin;
    }
    failed += unordered > 0;
    printf("spatial queue: %u jobs before a lower bin%s\n", unordered, unordered > 0 ? "  FAILED" : "");
    return failed;
}
