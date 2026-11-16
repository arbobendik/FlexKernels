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
// Domain of the sample of seed at p: x0 its seed, x1 on the pixel's center at depth 1 under a still pinhole, off it
// in x by edge pixels
static float edge = 0;
static Domain domainOf(Vector<int32_t, 2> p, uint32_t seed) {
    const float x = (p.x + 0.5f + edge) / W * 2 - 1, y = (1 - (p.y + 0.5f) / H) * 2 - 1;
    return Domain{Vector<float, 3>(float(seed), 0, 0), Vector<float, 3>(x, y, 1),
        Hit{Vector<float, 2>(0, 0), uint32_t(p.y * W + p.x), 0, 0, sqrtf(x * x + y * y + 1)}, 0};
}
// Partners off the image and in its last column have no domain
bool HookScene_storedDomainTemporal_0(Vector<int32_t, 2> q, uint32_t seed, Domain* dom) {
    *dom = domainOf(q, seed);
    return inside(q) && q.x != W - 1;
}
static Reservoir initial[W * H], previous[W * H];
static bool unchanged = false, scenes = true;
static int slot_reads = 0;
Reservoir HookScene_loadReservoirInitial_0(Vector<int32_t, 2> p) { return initial[p.y * W + p.x]; }
Reservoir HookScene_loadReservoirPrevious_0(Vector<int32_t, 2> q) { return previous[q.y * W + q.x]; }
Vector<uint32_t, 4> HookScene_reservoirPrevious_0(Vector<int32_t, 2> q, uint32_t) {
    const Reservoir& r = previous[q.y * W + q.x];
    return Vector<uint32_t, 4>(r.seed, r.path, *(const uint32_t*)&r.w, *(const uint32_t*)&r.c);
}
bool HookScene_storedDomainInitial_0(Vector<int32_t, 2> p, uint32_t seed, Domain* dom) {
    *dom = domainOf(p, seed);
    return inside(p);
}
Domain HookScene_previousDomain_0(Vector<int32_t, 2> q, uint32_t seed) { return domainOf(q, seed); }
bool HookScene_currentDomain_0(Vector<int32_t, 2> p, Domain* dom) { return HookScene_storedDomainInitial_0(p, 0, dom); }
bool HookScene_sceneUnchanged_0() { return unchanged; }
bool HookScene_previousScenes_0() { return scenes; }
Matrix<float, 3, 3> HookScene_viewMatrix_0() { return Matrix<float, 3, 3>(1, 0, 0, 0, 1, 0, 0, 0, 1); }
Matrix<float, 3, 3> HookScene_prevViewMatrix_0() { return HookScene_viewMatrix_0(); }
Vector<float, 3> HookScene_cameraPosition_0() { return Vector<float, 3>(0, 0, 0); }
Vector<float, 3> HookScene_prevCameraPosition_0() { return Vector<float, 3>(0, 0, 0); }
Vector<uint32_t, 4> HookScene_temporalShift_0(Vector<int32_t, 2>, uint32_t) {
    return slot_reads++, Vector<uint32_t, 4>(0);
}
void HookScene_storeTemporalShift_0(Vector<int32_t, 2>, uint32_t, Vector<uint32_t, 4>) {}
Vector<uint32_t, 4> HookScene_duplication_0(Vector<int32_t, 2>) { return Vector<uint32_t, 4>(0); }
uint32_t HookScene_restirDecorrelation_0() { return 0; }
void HookScene_storeReservoirTemporal_0(Vector<int32_t, 2>, Reservoir, Hit) {}
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
    // Temporal round: every job's domain is its sample's, none for the identity in an unchanged scene, t = 1 none
    // without previous scenes, and restir_temporal reads no shift the round ran none for
    for (int i = 0; i < W * H; i++) {
        initial[i] = previous[i] = Reservoir{};
        initial[i].seed = 1000 + i, previous[i].seed = 2000 + i;
        initial[i].w = previous[i].w = initial[i].c = previous[i].c = 1;
        initial[i].f = previous[i].f = Vector<float, 3>(1, 1, 1);
    }
    const auto jobs = [&](uint32_t t, int& misfits) {
        int count = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            ShiftJob job = {};
            if (temporalJob_0(Vector<int32_t, 2>(x, y), t, &job)) count++, misfits += job.dom.x0.x != float(job.r.seed);
        }
        return count;
    };
    int misfits = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (uint32_t t = 0; t < 3; t++) {
        ShiftJob job = {};
        if (spatialJob_0(Vector<int32_t, 2>(x, y), t, &job)) misfits += job.dom.x0.x != float(job.r.seed);
    }
    const int moved_current = jobs(0, misfits), moved_previous = jobs(1, misfits);
    scenes = false;
    const int unkept = jobs(1, misfits);
    unchanged = true;
    const int still = jobs(0, misfits) + jobs(1, misfits);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_temporal_hook(Vector<uint32_t, 3>(x, y, 0));
    const bool temporal = misfits == 0 && moved_current == W * H && moved_previous == W * H && unkept == 0 && still == 0
        && slot_reads == 0;
    failed += !temporal;
    printf("temporal round: %d domains off their sample's seed; jobs %d and %d in a changed scene, %d for t = 1 "
        "without previous scenes, %d unchanged; %d shifts read%s\n", misfits, moved_current, moved_previous, unkept,
        still, slot_reads, temporal ? "" : "  FAILED");
    // A still view's reprojection rounded off by a pixel keeps q = p
    edge = -0.5f - 1e-4f;
    int off = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        Domain dom = domainOf(Vector<int32_t, 2>(x, y), 1000 + y * W + x);
        const Vector<int32_t, 2> q = temporalNeighbor_0(Vector<int32_t, 2>(x, y), &dom, 1000 + y * W + x);
        off += q.x != x || q.y != y;
    }
    edge = 0;
    failed += off > 0;
    printf("temporal neighbour at a pixel's edge: %d of %d off their pixel%s\n", off, W * H, off > 0 ? "  FAILED" : "");
    return failed;
}
