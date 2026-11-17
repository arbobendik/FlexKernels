#include <stdio.h>
#include <string.h>
#include <algorithm>
#include <vector>
#include "pathtracer.cpp"

static const int W = 16, H = 8, BINS = 40;
static Reservoir temporal[W * H];
// Dispatch size, counts and cursors per bin, then the jobs
static uint32_t queue[3 + 2 * BINS + 3 * W * H];
static bool inside(Vector<int32_t, 2> p) { return p.x >= 0 && p.y >= 0 && p.x < W && p.y < H; }

Vector<uint32_t, 2> HookScene_renderSize_0() { return Vector<uint32_t, 2>(W, H); }
static uint32_t frame_number = 3;
uint32_t HookScene_frame_0() { return frame_number; }
uint32_t HookScene_restirNeighbours_0() { return 3; }
// A mutual pairing texture: each even column paired with the next, the sizes 254, 230 and 210 even
static bool mutual = false;
Vector<int32_t, 4> HookScene_pairing_0(Vector<int32_t, 2> texel, uint32_t t) {
    if (mutual) return Vector<int32_t, 4>(texel.x % 2 == 0 ? 1 : -1, 0, 0, 0);
    return Vector<int32_t, 4>(int(t) + 1 - texel.x % 3, texel.y % 2 - 1, 0, 0);
}
Reservoir HookScene_loadReservoirTemporal_0(Vector<int32_t, 2> p) { return temporal[p.y * W + p.x]; }
// Domain of the sample of seed at p: x0 its seed, x1 on the pixel's center at depth 1 under a still pinhole, off it
// in x by edge pixels
static float edge = 0;
static bool missed = false;
static Domain domainOf(Vector<int32_t, 2> p, uint32_t seed) {
    const float x = (p.x + 0.5f + edge) / W * 2 - 1, y = (1 - (p.y + 0.5f) / H) * 2 - 1;
    return Domain{Vector<float, 3>(float(seed), 0, 0), Vector<float, 3>(x, y, 1),
        Hit{Vector<float, 2>(0, 0), missed ? 0xFFFFFFFFu : uint32_t(p.y * W + p.x), seed, 0,
            sqrtf(x * x + y * y + 1)}, 0};
}
// Partners off the image and in its last column have no domain
// Target domains traced: of partners, and of previous samples here
static int target_traces = 0;
bool HookScene_storedDomainTemporal_0(Vector<int32_t, 2> q, uint32_t seed, Domain* dom) {
    target_traces++;
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
// Previous samples' seeds trace no domain in the current frame
static bool previous_unseen = false;
// Seeds asked for domains, in order, while recording, and every path missing
static std::vector<uint32_t> asked_seeds;
static bool recording = false, all_miss = false;
// Domains asked of the current and the previous frame
static int domain_asks = 0, previous_asks = 0;
bool HookScene_storedDomainInitial_0(Vector<int32_t, 2> p, uint32_t seed, Domain* dom) {
    if (recording) asked_seeds.push_back(seed);
    domain_asks++;
    target_traces += seed >= 2000;
    *dom = domainOf(p, seed);
    return inside(p) && !(previous_unseen && seed >= 2000) && !all_miss;
}
// The previous frame's domains moved off the current ones by moved in x0
static float moved = 0;
Domain HookScene_previousDomain_0(Vector<int32_t, 2> q, uint32_t seed) {
    previous_asks++;
    Domain dom = domainOf(q, seed);
    dom.x0.y = moved;
    return dom;
}
static int shifted_previous = 0, walked = 0, asked[2] = {};
Shift HookScene_shiftPrevious_0(Domain, Reservoir) { return shifted_previous++, Shift{Vector<float, 3>(1, 1, 1), 1}; }
// A path offers its own sample at its scale
Shift HookScene_walkCallable_0(Domain, Reservoir r, bool replay, float scale, Selection* sel) {
    r.f = Vector<float, 3>(1, 1, 1);
    if (!replay) offer(sel, r, Vector<float, 3>(scale, scale, scale));
    return walked += replay, Shift{Vector<float, 3>(1, 1, 1), 1};
}
static bool reuse = true;
static int missed_paths = 0;
static Vector<float, 4> added[W * H];
static Reservoir stored[W * H];
static Hit stored_hit[W * H];
bool HookScene_restirUsed_0() { return reuse; }
uint32_t HookScene_samples_0() { return 4; }
Vector<float, 3> HookScene_missed_0(Vector<int32_t, 2>, Domain, float) {
    return missed_paths++, Vector<float, 3>(0, 0, 0);
}
void HookScene_addColor_0(Vector<int32_t, 2> p, Vector<float, 4> color) { added[p.y * W + p.x] = color; }
void HookScene_storeReservoirInitial_0(Vector<int32_t, 2> p, Reservoir r, Hit hit) {
    stored[p.y * W + p.x] = r, stored_hit[p.y * W + p.x] = hit;
}
// The pinhole of domainOf
Vector<float, 2> HookScene_pixelOf_0(Vector<float, 3> x, bool previous) {
    asked[previous]++;
    return Vector<float, 2>((x.x / x.z * 0.5f + 0.5f) * W, (0.5f - x.y / x.z * 0.5f) * H);
}
bool HookScene_currentDomain_0(Vector<int32_t, 2> p, Domain* dom) { return *dom = domainOf(p, 0), inside(p); }
bool HookScene_sceneUnchanged_0() { return unchanged; }
bool HookScene_previousScenes_0() { return scenes; }
Matrix<float, 3, 3> HookScene_viewMatrix_0() { return Matrix<float, 3, 3>(1, 0, 0, 0, 1, 0, 0, 0, 1); }
Matrix<float, 3, 3> HookScene_prevViewMatrix_0() { return HookScene_viewMatrix_0(); }
Vector<float, 3> HookScene_cameraPosition_0() { return Vector<float, 3>(0, 0, 0); }
Vector<float, 3> HookScene_prevCameraPosition_0() { return Vector<float, 3>(0, 0, 0); }
// Slots written this frame, their shifts, and reads of slots not written
static bool written[2][W * H];
static Vector<uint32_t, 4> slots[2][W * H];
static int stale_reads = 0;
Vector<uint32_t, 4> HookScene_temporalShift_0(Vector<int32_t, 2> p, uint32_t t) {
    return slot_reads++, stale_reads += !written[t][p.y * W + p.x], slots[t][p.y * W + p.x];
}
void HookScene_storeTemporalShift_0(Vector<int32_t, 2> p, uint32_t t, Vector<uint32_t, 4> shifted) {
    written[t][p.y * W + p.x] = true, slots[t][p.y * W + p.x] = shifted;
}
// The temporal round's shifts from its queue, else made by restir_temporal
static bool queued_round = true;
bool HookScene_temporalQueued_0() { return queued_round; }
Vector<uint32_t, 4> HookScene_duplication_0(Vector<int32_t, 2>) { return Vector<uint32_t, 4>(0); }
uint32_t HookScene_restirDecorrelation_0() { return 0; }
static Reservoir reused[W * H];
void HookScene_storeReservoirTemporal_0(Vector<int32_t, 2> p, Reservoir r, Hit) { reused[p.y * W + p.x] = r; }
// The neighbours the count pass stored this frame
static Vector<int32_t, 2> neighbors[W * H];
static int neighbor_loads = 0;
void HookScene_storeTemporalNeighbor_0(Vector<int32_t, 2> p, Vector<int32_t, 2> q) { neighbors[p.y * W + p.x] = q; }
Vector<int32_t, 2> HookScene_loadTemporalNeighbor_0(Vector<int32_t, 2> p) {
    return neighbor_loads++, neighbors[p.y * W + p.x];
}
uint32_t HookScene_queueCountAdd_0(uint32_t bin, uint32_t jobs) { return (queue[3 + bin] += jobs) - jobs; }
uint32_t HookScene_queueCountLoad_0(uint32_t bin) { return queue[3 + bin]; }
uint32_t HookScene_queueCursorAdd_0(uint32_t bin, uint32_t jobs) { return (queue[3 + BINS + bin] += jobs) - jobs; }
void HookScene_queueJobStore_0(uint32_t index, uint32_t job) { queue[3 + 2 * BINS + index] = job; }
void HookScene_queueDispatchStore_0(uint32_t x, uint32_t y, uint32_t z) { queue[0] = x, queue[1] = y, queue[2] = z; }
uint32_t HookScene_queuedShifts_0(uint32_t index) { return queue[index]; }
void HookScene_storeShiftData_0(Vector<int32_t, 2>, uint32_t, Vector<uint32_t, 4>) {}
Vector<uint32_t, 4> HookScene_shiftData_0(Vector<int32_t, 2>, uint32_t) { return Vector<uint32_t, 4>(0); }
Vector<uint32_t, 4> HookScene_reservoirTemporal_0(Vector<int32_t, 2> q, uint32_t) {
    const Reservoir& r = temporal[q.y * W + q.x];
    return Vector<uint32_t, 4>(r.seed, r.path, *(const uint32_t*)&r.w, *(const uint32_t*)&r.c);
}
void HookScene_storeReservoirPrevious_0(Vector<int32_t, 2>, Reservoir, Hit) {}
void HookScene_storePreviousLayer_0(Vector<int32_t, 2>, uint32_t, Vector<uint32_t, 4>) {}

int main() {
    int failed = 0;
    // Over a mutual pairing texture every flip and transpose pairs both ways: partner(partner(p)) = p, for pixels
    // across the texture's wrap
    mutual = true;
    int unpaired = 0, flips = 0, pairs = 0;
    for (frame_number = 0; frame_number < 64; frame_number++) for (uint32_t t = 0; t < 3; t++) {
        flips |= 1 << (hash(frame_number * 3 + t) & 7);
        for (int y = 0; y < 300; y += 7) for (int x = 0; x < 600; x += 3) {
            const Vector<int32_t, 2> p(x, y), q = partner_0(p, t);
            // Partners off the image are dropped by every caller
            if (q.x < 0 || q.y < 0) continue;
            const Vector<int32_t, 2> back = partner_0(q, t);
            unpaired += back.x != p.x || back.y != p.y, pairs++;
        }
    }
    mutual = false, frame_number = 3;
    failed += unpaired > 0 || flips != 255 || pairs == 0;
    printf("mutual pairing: %d of %d pairs over every flip and transpose unpaired%s\n", unpaired, pairs,
        unpaired > 0 || flips != 255 ? "  FAILED" : "");
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
        if (spatialJob_0(Vector<int32_t, 2>(x, y), t, &job, false)) expected.push_back(x | y << 14 | t << 28);
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
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
            restir_temporal_count_hook(Vector<uint32_t, 3>(x, y, 0), 0);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            ShiftJob job = {};
            if (temporalJob_0(Vector<int32_t, 2>(x, y), neighbors[y * W + x], t, &job, true))
                count++, misfits += job.dom.x0.x != float(job.r.seed);
        }
        return count;
    };
    int misfits = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (uint32_t t = 0; t < 3; t++) {
        ShiftJob job = {};
        if (spatialJob_0(Vector<int32_t, 2>(x, y), t, &job, true)) misfits += job.dom.x0.x != float(job.r.seed);
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
    // Shift passes: job 1 into the previous frame's scene, job 0 and the spatial round through the consumer's walk
    const auto drain = [&](void (*count)(Vector<uint32_t, 3>, uint32_t), void (*prepass)(Vector<uint32_t, 3>, uint32_t),
        void (*shift)(Vector<uint32_t, 3>, uint32_t)) {
        for (uint32_t& word : queue) word = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) count(Vector<uint32_t, 3>(x, y, 0), 0);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) prepass(Vector<uint32_t, 3>(x, y, 0), 0);
        for (uint32_t group = 0; group < queue[0] * queue[1]; group++) for (uint32_t local = 0; local < 64; local++)
            shift(Vector<uint32_t, 3>(group % 65535, group / 65535, 0), local);
    };
    unchanged = false, scenes = true, moved = 1;
    drain(restir_temporal_count_hook, restir_temporal_prepass_hook, restir_temporal_shift_hook);
    const int temporal_walked = walked;
    walked = 0;
    drain(restir_count_hook, restir_prepass_hook, restir_shift_hook);
    // The spatial round walks the jobs whose partner's domain the shift pass finds
    int found = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) for (uint32_t t = 0; t < 3; t++) {
        ShiftJob job = {};
        found += spatialJob_0(Vector<int32_t, 2>(x, y), t, &job, true);
    }
    const bool through = shifted_previous == W * H && temporal_walked == W * H && walked == found;
    failed += !through;
    printf("shift passes: %d previous-scene shifts, %d walks in the temporal and %d in the spatial round%s\n",
        shifted_previous, temporal_walked, walked, through ? "" : "  FAILED");
    // Reprojection by the consumer's pixelOf; a missed sample keeps no neighbour but its own pixel's
    asked[0] = asked[1] = 0;
    int kept = 0, lost = 0;
    for (int run = 0; run < 2; run++) {
        moved = run, missed = true;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            Domain dom = domainOf(Vector<int32_t, 2>(x, y), 1000 + y * W + x);
            const Vector<int32_t, 2> q = temporalNeighbor_0(Vector<int32_t, 2>(x, y), &dom, 1000 + y * W + x);
            run ? lost += q.x < 0 : kept += q.x == x && q.y == y;
        }
        missed = false;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            Domain dom = domainOf(Vector<int32_t, 2>(x, y), 1000 + y * W + x);
            temporalNeighbor_0(Vector<int32_t, 2>(x, y), &dom, 1000 + y * W + x);
        }
    }
    moved = 0;
    const bool projected = kept == W * H && lost == W * H && asked[1] == W * H;
    failed += !projected;
    printf("reprojection: %d previous pixels asked of pixelOf; missed samples %d kept still, %d without a neighbour "
        "moved%s\n", asked[1], kept, lost, projected ? "" : "  FAILED");
    // A previous sample without a domain here runs no shift, and restir_temporal reads the zero its prepass wrote
    unchanged = false, scenes = true, moved = 1, previous_unseen = true, slot_reads = stale_reads = 0;
    for (auto& slots : written) for (bool& w : slots) w = false;
    drain(restir_temporal_count_hook, restir_temporal_prepass_hook, restir_temporal_shift_hook);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_temporal_hook(Vector<uint32_t, 3>(x, y, 0));
    previous_unseen = false, moved = 0;
    failed += slot_reads == 0 || stale_reads > 0;
    printf("unseen previous samples: %d shift slots read, %d not written this frame%s\n", slot_reads, stale_reads,
        slot_reads == 0 || stale_reads > 0 ? "  FAILED" : "");
    // An unchanged view asks no domain in the whole round and runs no job; a pixel whose own sample misses keeps
    // its previous reservoir
    unchanged = true, all_miss = true, domain_asks = previous_asks = walked = shifted_previous = 0;
    drain(restir_temporal_count_hook, restir_temporal_prepass_hook, restir_temporal_shift_hook);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_temporal_hook(Vector<uint32_t, 3>(x, y, 0));
    int history = 0;
    for (const Reservoir& r : reused) history += r.c == 2;
    unchanged = all_miss = false;
    const bool still_view = domain_asks == 0 && previous_asks == 0 && walked + shifted_previous == 0 && queue[0] == 0
        && history == W * H;
    failed += !still_view;
    printf("unchanged view: %d domains and %d previous domains asked, %d jobs run; %d of %d missed samples keep their "
        "history%s\n", domain_asks, previous_asks, walked + shifted_previous, history, W * H,
        still_view ? "" : "  FAILED");
    // A changed view asks each pixel's own domain once in the count pass, a target per job in the shift pass, and
    // none in restir_temporal, which reads the neighbour the count pass stored
    unchanged = false, scenes = true, moved = 1, walked = shifted_previous = 0;
    for (uint32_t& word : queue) word = 0;
    recording = true, asked_seeds.clear(), domain_asks = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
        restir_temporal_count_hook(Vector<uint32_t, 3>(x, y, 0), 0);
    recording = false;
    int own = 0;
    for (int i = 0; i < W * H; i++) own += asked_seeds[i] == uint32_t(1000 + i);
    const int count_asks = domain_asks;
    domain_asks = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
        restir_temporal_prepass_hook(Vector<uint32_t, 3>(x, y, 0), 0);
    const int prepass_asks = domain_asks;
    domain_asks = previous_asks = 0;
    for (uint32_t group = 0; group < queue[0] * queue[1]; group++) for (uint32_t local = 0; local < 64; local++)
        restir_temporal_shift_hook(Vector<uint32_t, 3>(group % 65535, group / 65535, 0), local);
    const int shift_asks = domain_asks + previous_asks, shift_jobs = walked + shifted_previous;
    domain_asks = previous_asks = neighbor_loads = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_temporal_hook(Vector<uint32_t, 3>(x, y, 0));
    moved = 0;
    const bool lookups = count_asks == W * H && own == W * H && prepass_asks == 0 && shift_asks == shift_jobs
        && shift_jobs > 0 && domain_asks + previous_asks == 0 && neighbor_loads == W * H;
    failed += !lookups;
    printf("changed view: %d own domains of %d asked by the count pass, %d by the prepass, %d for %d jobs, %d by "
        "restir_temporal reading %d stored neighbours%s\n", count_asks, own, prepass_asks, shift_asks, shift_jobs,
        domain_asks + previous_asks, neighbor_loads, lookups ? "" : "  FAILED");
    // Unqueued, restir_temporal makes each pixel's two shifts itself: the queued round's output bit for bit, reading no
    // stored neighbour or shift slot
    moved = 1;
    drain(restir_temporal_count_hook, restir_temporal_prepass_hook, restir_temporal_shift_hook);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_temporal_hook(Vector<uint32_t, 3>(x, y, 0));
    std::vector<Reservoir> from_queue(reused, reused + W * H);
    queued_round = false, slot_reads = neighbor_loads = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_temporal_hook(Vector<uint32_t, 3>(x, y, 0));
    queued_round = true, moved = 0;
    int differ = 0;
    for (int i = 0; i < W * H; i++) differ += memcmp(&from_queue[i], &reused[i], sizeof(Reservoir)) != 0;
    const bool inline_round = differ == 0 && slot_reads == 0 && neighbor_loads == 0;
    failed += !inline_round;
    printf("unqueued temporal round: %d of %d pixels differ from the queued round's, %d slots and %d neighbours "
        "read%s\n", differ, W * H, slot_reads, neighbor_loads, inline_round ? "" : "  FAILED");
    // Initial pass: a domain per path by its seed, missed paths to the consumer keeping c = 1, the winner's hit stored,
    // and ReSTIR off summing every path
    const auto initial_pass = [&]() {
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_initial_hook(Vector<uint32_t, 3>(x, y, 0));
    };
    recording = true, asked_seeds.clear();
    initial_pass();
    recording = false;
    int seeds_off = 0, hits_off = 0, colored = 0;
    for (int y = 0, k = 0; y < H; y++) for (int x = 0; x < W; x++) {
        const uint32_t pixel_seed = stream(hash(HookScene_frame_0()), x + W * y);
        for (uint32_t i = 0; i < 4; i++) seeds_off += asked_seeds[k++] != stream(pixel_seed, i);
        hits_off += stored_hit[y * W + x].triangle_index != stored[y * W + x].seed || !(stored[y * W + x].w > 0);
        colored += added[y * W + x].x != 0 || added[y * W + x].w != 1;
    }
    all_miss = true;
    initial_pass();
    all_miss = false;
    int unmet = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
        unmet += stored[y * W + x].c == 1
            && stored[y * W + x].seed == stream(stream(hash(HookScene_frame_0()), x + W * y), 0);
    reuse = false;
    initial_pass();
    reuse = true;
    int summed = 0;
    for (const auto& c : added) summed += fabsf(c.x - 1) < 1e-6f && c.w == 1;
    const bool initial = asked_seeds.size() == 4 * W * H && seeds_off == 0 && hits_off == 0 && colored == 0
        && missed_paths == 4 * W * H && unmet == W * H && summed == W * H;
    failed += !initial;
    printf("initial pass: %d of %zu domains off their path's seed, %d winners' hits off, %d missed paths, %d of %d "
        "all-missed pixels kept, %d of %d summed to 1%s\n", seeds_off, asked_seeds.size(), hits_off, missed_paths,
        unmet, W * H, summed, W * H, initial ? "" : "  FAILED");
    // Count and prepass trace no target, an unchanged view none at all; a target missing at the shift runs none
    unchanged = false, scenes = true, moved = 1;
    using Pass = void (*)(Vector<uint32_t, 3>, uint32_t);
    const auto judged = [&](Pass count, Pass prepass) {
        for (uint32_t& word : queue) word = 0;
        target_traces = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) count(Vector<uint32_t, 3>(x, y, 0), 0);
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) prepass(Vector<uint32_t, 3>(x, y, 0), 0);
        return target_traces;
    };
    const int changed_temporal = judged(restir_temporal_count_hook, restir_temporal_prepass_hook),
        changed_spatial = judged(restir_count_hook, restir_prepass_hook);
    unchanged = true;
    const int unchanged_temporal = judged(restir_temporal_count_hook, restir_temporal_prepass_hook);
    unchanged = false, previous_unseen = true, walked = shifted_previous = 0;
    drain(restir_temporal_count_hook, restir_temporal_prepass_hook, restir_temporal_shift_hook);
    previous_unseen = false, moved = 0;
    const bool lazy = changed_temporal == 0 && changed_spatial == 0 && unchanged_temporal == 0 && walked == 0
        && shifted_previous == W * H;
    failed += !lazy;
    printf("judging jobs: %d and %d targets traced in a changed scene, %d unchanged; unseen targets %d walks, %d "
        "previous-scene shifts%s\n", changed_temporal, changed_spatial, unchanged_temporal, walked, shifted_previous,
        lazy ? "" : "  FAILED");
    // Spatial reuse's colour to the consumer unclamped, without the primary surface
    for (int i = 0; i < W * H; i++)
        ::temporal[i].f = Vector<float, 3>(1e9f, 1e9f, 1e9f), ::temporal[i].c = 1, added[i] = Vector<float, 4>(0);
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) restir_spatial_hook(Vector<uint32_t, 3>(x, y, 0));
    int unclamped = 0, offered = 0;
    for (int i = 0; i < W * H; i++) offered += ::temporal[i].w > 0, unclamped += added[i].x > 65519 && added[i].w == 0;
    failed += unclamped != offered;
    printf("spatial colour: %d of %d pixels above 65519 to addColor%s\n", unclamped, offered,
        unclamped != offered ? "  FAILED" : "");
    return failed;
}
