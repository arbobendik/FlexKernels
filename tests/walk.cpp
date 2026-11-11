#include <stdio.h>
#include <math.h>
#include <vector>
#include <initializer_list>
#include "pathtracer.cpp"
#include "lobes.h"

using V = Vector<float, 3>;
static const V ZERO(0, 0, 0), ONE(1, 1, 1);
static float dotv(V a, V b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V scaled(V a, float s) { return V(a.x * s, a.y * s, a.z * s); }
struct Shape { V center; float radius; bool inward; Material layer[2]; unsigned layers; float coverage; bool encloses;
    Medium volume; bool hidden = false; };
static std::vector<Shape> scene;
static const Hit NO_HIT = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, 0};
static Medium camera_fog = {ZERO, ZERO};
static float handed_distance;
static V segment_start;
static bool checking = false;
static int segments = 0, misfits = 0;
static Material lambert(float albedo, float emits) {
    return Material{scaled(ONE, albedo), scaled(ONE, emits), 1, 0, 0, 1, ONE, ONE, 1, ZERO, ZERO, 0.5f, 0, 0, ZERO};
}
static Material dielectric(float ior) {
    return Material{ONE, ZERO, 0, 0, 1, ior, ONE, ONE, 1, ZERO, ZERO, 0.5f, 0, 0, ZERO};
}

static Hit last_shaded = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, 0};
static int skips = 0, skip_misfits = 0;
static V last_point;
static float last_ior = 1;
Hit HookScene_traverseInstanceBVH_0(Ray ray, bool, float max_len, bool surface, Hit left, bool viewed) {
    if (left.instance_index != 0xFFFFFFFFu)
        skips++, skip_misfits += left.instance_index != last_shaded.instance_index
            || left.distance != last_shaded.distance
            || ray.origin.x != last_point.x || ray.origin.y != last_point.y || ray.origin.z != last_point.z
            || last_ior != 1;
    Hit hit = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, max_len};
    const float near = surface ? 1e-4f : 0.0f;
    for (unsigned i = 0; i < scene.size(); i++) {
        if (viewed && scene[i].hidden) continue;
        const V oc = ray.origin - scene[i].center;
        const float b = dotv(oc, ray.unit_direction), c = dotv(oc, oc) - scene[i].radius * scene[i].radius;
        if (b * b - c < 0) continue;
        const float s = sqrtf(b * b - c), t = -b - s > near ? -b - s : -b + s;
        if (t > near && t < hit.distance) hit.instance_index = i, hit.distance = t;
    }
    return hit;
}
static V handed_direction;
static int shaded_misfits = 0;
Surface HookScene_surfaceAtPath_0(Hit hit, V origin, uint32_t state, float, uint32_t layer, uint32_t depth, uint32_t,
    V dir) {
    last_shaded = hit, last_point = origin, last_ior = scene[hit.instance_index].layer[layer].ior;
    shaded_misfits += depth == 0 && camera_fog.extinction.x == 0
        && (dir.x != handed_direction.x || dir.y != handed_direction.y || dir.z != handed_direction.z);
    const Shape& s = scene[hit.instance_index];
    const V n = scaled(origin - s.center, (s.inward ? -1 : 1) / s.radius);
    return Surface{n, n, 1e-4f, s.layer[layer], false, state, s.coverage, s.encloses, s.volume, 0xFFFFFFFFu};
}
Surface HookScene_surfaceAt_0(Hit hit, V origin, uint32_t state) {
    return HookScene_surfaceAtPath_0(hit, origin, state, 0, 0, 1, 0, ZERO);
}
Surface HookScene_lightSurfaceAt_0(Hit hit, V point, uint32_t state, V, uint32_t, float) {
    return HookScene_surfaceAt_0(hit, point, state);
}
uint32_t HookScene_layers_0(Hit hit) { return scene[hit.instance_index].layers; }
// Sun: irradiance 1 along -x, a delta light 1e4 along +x of intensity 1e8
static bool sun = false;
static const V SUN(1e4f, 0, 0);
Vector<uint32_t, 4> HookScene_lightNode_0(uint32_t) { return Vector<uint32_t, 4>(sun ? 2 : 1, 0, 0, 0); }
uint32_t HookScene_lightSecond_0(uint32_t) { return 0; }
LightBounds HookScene_lightBounds_0(uint32_t) {
    return sun ? LightBounds{SUN, SUN, V(1, 0, 0), 1, -1} : LightBounds{ZERO, ZERO, V(0, 0, 1), 0, 1};
}
Vector<uint32_t, 4> HookScene_lightTrail_0(uint32_t) { return Vector<uint32_t, 4>(0, 0, 0, 0); }
uint32_t HookScene_lightSlot_0(Hit) { return 0; }
static bool slot_leaf = false;
bool HookScene_slotLeaf_0(uint32_t, uint32_t, Vector<uint32_t, 4>) { return slot_leaf; }
Light HookScene_light_0(uint32_t) { return Light{SUN, 0, ONE, 1e8f, 0}; }
uint32_t HookScene_triangleOffset_0(uint32_t) { return 0; }
Matrix<float, 3, 3> HookScene_worldTriangle_0(uint32_t, uint32_t) { return Matrix<float, 3, 3>(0.0f); }
V HookScene_calculatePointLightContrib_0(uint32_t) { return ZERO; }
V HookScene_hitPosition_0(Hit) { return ZERO; }
// Shadows pass index-matched clear surfaces and the uncovered share of others, media by exp(-extinction * d)
static V shadowThrough(Ray ray, float l, bool surface) {
    float share = 1;
    for (float along = 0;; surface = true) {
        const Hit hit = HookScene_traverseInstanceBVH_0(ray, false, l - along, surface, NO_HIT, false);
        if (hit.instance_index == 0xFFFFFFFFu) return scaled(ONE, share);
        const Material& m = scene[hit.instance_index].layer[0];
        if (!(m.transmission == 1 && m.ior == 1 && scene[hit.instance_index].layers == 1))
            share *= 1 - scene[hit.instance_index].coverage;
        if (!(share > 0)) return ZERO;
        along += hit.distance, ray.origin = ray.origin + scaled(ray.unit_direction, hit.distance);
    }
}
V HookScene_shadowTransmittance_0(Ray ray, float l) { return shadowThrough(ray, l, true); }
V HookScene_shadowTransmittanceIn_0(Ray ray, float l, V extinction, uint32_t, uint32_t, uint32_t, uint32_t,
    bool surface, float length, float) {
    const V from = ray.origin - segment_start;
    if (checking && !surface) segments++, misfits += fabsf(sqrtf(dotv(from, from)) - length) > 1e-6f;
    const float inside = fminf(HookScene_traverseInstanceBVH_0(ray, false, l, surface, NO_HIT, false).distance, l);
    const V through = shadowThrough(ray, l, surface);
    return V(through.x * expf(-extinction.x * inside), through.y * expf(-extinction.y * inside),
        through.z * expf(-extinction.z * inside));
}
static uint32_t bounces = 64;
uint32_t HookScene_maxBounces_0() { return bounces; }
static float sky = 1;
static bool escapes_checked = false;
static int escapes = 0, escape_misfits = 0;
V HookScene_env_map_sample_0(V, uint32_t depth, uint32_t lobe) {
    if (escapes_checked) escapes += depth == 0 && lobe == 0, escape_misfits += depth != 0 || lobe != 0 && lobe != 3;
    return scaled(ONE, sky);
}
V HookScene_ambient_0() { return ONE; }
Vector<uint32_t, 2> HookScene_environmentMapSize_0() { return Vector<uint32_t, 2>(4, 2); }
static bool cdf = true;
static int cdf_reads = 0;
Vector<uint32_t, 2> HookScene_environmentCdfSize_0() { return Vector<uint32_t, 2>(cdf ? 5 : 1, cdf ? 2 : 1); }
Vector<float, 4> HookScene_environmentCdf_0(Vector<uint32_t, 2> cell) {
    cdf_reads++;
    return cell.x == 4 ? Vector<float, 4>((cell.y + 1) / 2.0f, 0.5f, 0, 0)
        : Vector<float, 4>((cell.x + 1) / 4.0f, 0.25f, 0, 0);
}
static bool varying = false;
Medium HookScene_cameraMedium_0(V direction, float distance, uint32_t* filling) {
    handed_direction = direction, handed_distance = distance;
    *filling = varying ? 0 : 0xFFFFFFFFu;
    return camera_fog;
}
float HookScene_majorant_0(uint32_t) { return camera_fog.extinction.x; }
static int tracked = 0, tracked_misfits = 0, walk_tracks = 0;
float HookScene_trackMedium_0(uint32_t, V, V, float distance, uint32_t* state, V* weight, V*, V* scatter, V* extinction,
    uint32_t, uint32_t, bool camera) {
    tracked++, tracked_misfits += camera != (walk_tracks++ == 0);
    const Random u = pcg(*state);
    *state = u.state;
    const float along = -logf(1 - u.value) / camera_fog.extinction.x;
    if (along < distance) {
        *weight = scaled(*weight, camera_fog.scatter.x / camera_fog.extinction.x);
        *scatter = camera_fog.scatter, *extinction = camera_fog.extinction;
    }
    return along < distance ? along : 2 * distance;
}

static bool summing = false, seen = false;
static double furnace(const char* name, V camera, V aim, float angle, double truth, int& failed, float absorbs = 0) {
    const int N = 1 << 17;
    double sum = 0, sum2 = 0, through = 0;
    for (int i = 0; i < N; i++) {
        Random u = pcg(hash(3 * i + 1)), v = pcg(u.state);
        const float z = 1 - u.value * (1 - cosf(angle)), r = sqrtf(fmaxf(0, 1 - z * z)), phi = 6.2831853f * v.value;
        const V w = scaled(aim - camera, 1 / sqrtf(dotv(aim - camera, aim - camera)));
        const V t = fabsf(w.x) < 0.9f ? V(1, 0, 0) : V(0, 1, 0), a = scaled(t - scaled(w, dotv(t, w)),
            1 / sqrtf(1 - dotv(t, w) * dotv(t, w)));
        const V b(w.y * a.z - w.z * a.y, w.z * a.x - w.x * a.z, w.x * a.y - w.y * a.x);
        const V dir = scaled(a, r * cosf(phi)) + scaled(b, r * sinf(phi)) + scaled(w, z);
        const Hit hit = HookScene_traverseInstanceBVH_0(Ray{camera, dir}, true, 1e30f, true, NO_HIT, true);
        Domain dom = {camera, camera + scaled(dir, hit.distance), hit};
        Reservoir path = {};
        path.seed = hash(3 * i + 2);
        Selection sel = {};
        sel.random_state = hash(3 * i + 3);
        sel.sums = summing;
        segment_start = camera, walk_tracks = 0;
        walk_hook(dom, path, false, 1, &sel);
        misfits += dotv(handed_direction, dir) < 1 - 1e-6f
            || fabsf(handed_distance - hit.distance) > 1e-5f * hit.distance;
        const double y = sel.color.x + (seen ? sel.glow.x : 0);
        through += exp(-absorbs * hit.distance);
        sum += y, sum2 += y * y;
    }
    const double mean = sum / N, se = sqrt(fmax(sum2 / N - mean * mean, 0) / N);
    truth *= through / N;
    const bool ok = truth != truth || (fabs(mean - truth) < fmax(4 * se, 1e-4) && se < 0.01);
    failed += !ok;
    printf("%-28s %.5f +- %.5f of %.5f%s\n", name, mean, se, truth, ok ? "" : "  FAILED");
    return mean;
}

int main() {
    int failed = 0;
    const V camera(0, 0, 3), center(0, 0, 0);
    const Medium none = {ZERO, ZERO}, fog = {scaled(ONE, 2), scaled(ONE, 2)};
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    escapes_checked = true;
    furnace("white sphere", camera, center, 0.3f, 1, failed);
    escapes_checked = false;
    // Sky without a luminance distribution: escapes alone bring it all
    cdf = false, cdf_reads = 0;
    furnace("white sphere, sky unsampled", camera, center, 0.3f, 1, failed);
    failed += cdf_reads > 0;
    printf("sky unsampled: %d reads of its distribution%s\n", cdf_reads, cdf_reads > 0 ? "  FAILED" : "");
    cdf = true;
    summing = true;
    furnace("white sphere, ReSTIR off", camera, center, 0.3f, 1, failed);
    // A white sheen over it drawn as its own lobe, reconnected and replayed by ReSTIR
    scene[0].layer[0].sheen = ONE, scene[0].layer[0].sheen_roughness = 0.5f;
    furnace("white sheen, ReSTIR off", camera, center, 0.3f, 1, failed);
    summing = false;
    furnace("white sheen", camera, center, 0.3f, 1, failed);
    {
        // Paths leaving the sphere by its sheen lobe (walk.slang's PATH_LOBE_PREV at bit 15, LOBE_SHEEN_VELVET 4) that a
        // neighbouring primary hit takes, shifted there and back up to the environment reconnection's rounding
        const auto seen = [&](V dir) {
            const Hit hit = HookScene_traverseInstanceBVH_0(Ray{camera, dir}, true, 1e30f, true, NO_HIT, true);
            return Domain{camera, camera + scaled(dir, hit.distance), hit};
        };
        const Domain near = seen(V(0, 0, -1)), off = seen(V(sinf(0.02f), 0, -cosf(0.02f)));
        int sheened = 0, back = 0;
        for (int i = 0; i < 16384; i++) {
            Reservoir path = {};
            path.seed = hash(3 * i + 2);
            Selection sel = {};
            sel.random_state = hash(3 * i + 3);
            walk_hook(near, path, false, 1, &sel);
            const Reservoir r = finalize(sel, 1);
            if (!(r.w > 0) || (r.path >> 15 & 7u) != 4u) continue;
            const Shift to = shift_hook(off, r);
            if (!(to.f.x > 0)) continue;
            Reservoir moved = r;
            moved.f = to.f;
            const Shift home = shift_hook(near, moved);
            sheened++, back += fabsf(home.f.x - r.f.x) <= 1e-4f * r.f.x;
        }
        const bool kept = sheened > 256 && back == sheened;
        failed += !kept;
        printf("replay of the sheen lobe: %d of %d paths there and back within 1e-4%s\n", back, sheened,
            kept ? "" : "  FAILED");
    }
    scene[0].layer[0] = lambert(1, 0);
    scene[0].coverage = 0.3f;
    furnace("white sphere covered at 0.3", camera, center, 0.3f, 1, failed);
    scene[0].layer[0] = lambert(0, 0);
    furnace("black sphere covered at 0.3", camera, center, 0.3f, 0.49, failed);
    scene = {{center, 1, false, {dielectric(1.5f), dielectric(1.5f)}, 2, 1, false, none}};
    furnace("coat over glass", camera, center, 0.3f, 1, failed);
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, fog}};
    furnace("medium of albedo 1", camera, center, 0.3f, 1, failed);
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, false, none}, {center, 0.5f, false, {lambert(1, 0)}, 1, 1, false,
        none}};
    furnace("white sphere in a shell", camera, center, 0.15f, 1, failed);
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}, {V(0, 0, 3.2f), 2, false, {dielectric(1)}, 1, 1,
        false, none}};
    furnace("white sphere beside a shell", V(2.2f, 0, 0.6f), V(0, 0, 0.6f), 0.1f, 1, failed);
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    camera_fog = {ZERO, scaled(ONE, 0.5f)};
    furnace("white sphere in an absorber", camera, center, 0.3f, 1, failed, 0.5f);
    camera_fog = none;
    scene = {{center, 1, true, {lambert(0.5f, 1)}, 1, 1, false, none}};
    furnace("inside walls of albedo 0.5", center, V(0, 0, 1), 3.14159265f, 1, failed);
    scene = {{center, 1, false, {lambert(0.5f, 1)}, 1, 1, false, none}};
    furnace("inside walls faced out", center, V(0, 0, 1), 3.14159265f, 1, failed);
    bounces = 0, sky = 0;
    for (const float sigma : {0.2f, 0.5f}) {
        // (sigma / 4 pi) int_0^1 exp(-sigma (s + sqrt(1 - s^2))) ds by Simpson's rule over s = sin t, and exp(-sigma)
        const double in_scattered = sigma == 0.2f ? 0.0123111280712487 : 0.0209620516427305;
        camera_fog = {scaled(ONE, sigma), scaled(ONE, sigma)};
        char name[64];
        for (int run = 0; run < 4; run++) {
            varying = run & 1, summing = run & 2;
            const char* kind = varying ? (summing ? "varying, ReSTIR off" : "varying") : (summing ? "ReSTIR off" : "");
            sun = true, seen = false;
            scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, camera_fog}};
            snprintf(name, sizeof name, "sun in fog %.1f %s", sigma, kind);
            furnace(name, center, V(0, 0, -1), 0, in_scattered, failed);
            sun = false, seen = true;
            scene = {{center, 1, true, {lambert(0, 1)}, 1, 1, false, none}};
            snprintf(name, sizeof name, "walls in fog %.1f %s", sigma, kind);
            furnace(name, center, V(0, 0, -1), 0, exp(-double(sigma)), failed);
        }
    }
    // Single and double scattering: 0.0123111 + 0.001953, the double by Monte Carlo
    bounces = 1, sun = true, seen = false, varying = summing = false;
    camera_fog = {scaled(ONE, 0.2f), scaled(ONE, 0.2f)};
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, camera_fog}};
    furnace("sun in fog 0.2, bounces 1", center, V(0, 0, -1), 0, 0.014264, failed);
    // (s / 4 pi) int_0^T exp(-s (t + sqrt(1 - t^2) - x)) dt at the camera's x, by scipy's quad
    bounces = 0;
    camera_fog = {scaled(ONE, 10), scaled(ONE, 10)};
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, camera_fog}};
    checking = true;
    furnace("sun in fog by its face", V(1 - 0.5e-4f, 0, 0), V(1 - 0.5e-4f, 0, -1), 0, 0.00757074921909657, failed);
    checking = false;
    sun = true, varying = summing = false, camera_fog = {scaled(ONE, 0.5f), scaled(ONE, 0.5f)};
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, camera_fog}};
    const auto domain = [&](V dir) {
        const Hit hit = HookScene_traverseInstanceBVH_0(Ray{center, dir}, true, 1e30f, true, NO_HIT, false);
        return Domain{center, center + scaled(dir, hit.distance), hit};
    };
    const Domain here = domain(V(0, 0, -1)), there = domain(V(sinf(0.1f), 0, -cosf(0.1f)));
    int scattered = 0, kept = 0;
    for (int i = 0; i < 4096; i++) {
        Reservoir path = {};
        path.seed = hash(3 * i + 2);
        Selection sel = {};
        sel.random_state = hash(3 * i + 3);
        walk_hook(here, path, false, 1, &sel);
        const Reservoir r = finalize(sel, 1);
        const Shift to = shift_hook(there, r);
        Reservoir moved = r;
        moved.f = to.f;
        const Shift back = shift_hook(here, moved);
        scattered += r.w > 0;
        kept += r.w > 0 && to.f.x > 0 && to.jac == 1 && back.jac == 1 && back.f.x == r.f.x && back.f.z == r.f.z;
    }
    const bool replayed = scattered > 256 && kept == scattered;
    failed += !replayed;
    printf("replay in fog: %d of %d scattered paths there and back exactly%s\n", kept, scattered,
        replayed ? "" : "  FAILED");
    // Black shell covered at 0.5 around an emitter of 1: 0 without a bounce, 0.5 with one
    bounces = 0, sky = 0, sun = false, camera_fog = none;
    scene = {{center, 2, false, {lambert(0, 0)}, 1, 0.5f, false, none}, {center, 1, false, {lambert(0, 1)}, 1, 1, false,
        none}};
    furnace("emitter through a cutout, no bounce", V(0, 0, 5), center, 0.1f, 0, failed);
    bounces = 1, skips = 0;
    furnace("emitter through a cutout", V(0, 0, 5), center, 0.1f, 0.5, failed);
    failed += skips == 0 || skip_misfits > 0;
    printf("straight passes: %d skipped, %d misfits%s\n", skips, skip_misfits,
        skips == 0 || skip_misfits > 0 ? "  FAILED" : "");
    bounces = 64, sky = 1;
    // 0.25 E[0.5^(2 sqrt(1 - (5 sin t)^2))] over the camera's cone, by scipy's quad
    bounces = 64, sky = 1, sun = false, camera_fog = none;
    for (const bool inward : {false, true}) {
        const char* turn = inward ? ", turned in" : "";
        char name[64];
        Material ball = dielectric(1);
        ball.absorption = scaled(ONE, 0.5f);
        scene = {{center, 2, inward, {lambert(0, 0)}, 1, 0.5f, false, none}, {center, 1, false, {lambert(1, 0)}, 1, 1,
            false, none}};
        snprintf(name, sizeof name, "sphere in a cutout%s", turn);
        furnace(name, V(0, 0, 5), center, 0.1f, 0.25, failed);
        scene[1] = {center, 1, false, {ball}, 1, 1, true, none};
        snprintf(name, sizeof name, "absorber in a cutout%s", turn);
        furnace(name, V(0, 0, 5), center, 0.1f, 0.0685110023574737, failed);
    }
    Material ball = dielectric(1);
    ball.absorption = scaled(ONE, 0.5f);
    scene = {{center, 1, false, {ball}, 1, 0.5f, true, none}};
    furnace("cutout absorber", V(0, 0, 5), center, 0.1f, 4 * 0.0685110023574737, failed);
    // Emitter of 1 inside each, seen straight: 0 hidden; visible 1, 1, 1 and e^-0.6
    bounces = 4, sky = 0, sun = false, camera_fog = none;
    for (int restir = 0; restir < 2; restir++) {
        summing = !restir;
        for (int k = 0; k < 4; k++)
            for (int hide = 0; hide < 2; hide++) {
                const Shape front = k == 1 ? Shape{center, 2, false, {lambert(0, 0)}, 1, 0, false, none}
                    : Shape{center, k == 3 ? 1.6f : 2, false, {dielectric(1)}, 1, 1, k >= 2,
                        k == 3 ? Medium{ZERO, ONE} : none};
                scene = {front, {center, 1, false, {lambert(0, 1)}, 1, 1, false, none, hide == 1}};
                const char* kinds[] = {"glass", "cutout", "void box", "absorbing box"};
                char name[64];
                snprintf(name, sizeof name, "%s %s%s", hide ? "hidden" : "seen", kinds[k],
                    restir ? "" : ", ReSTIR off");
                furnace(name, V(0, 0, 5), center, 0, hide ? 0 : k == 3 ? exp(-0.6) : 1, failed);
            }
    }
    summing = false;
    const auto twins = [&](const char* name, V camera, V aim, float angle, unsigned emitter) {
        scene[emitter].hidden = false;
        const double seen = furnace("  seen", camera, aim, angle, NAN, failed);
        scene[emitter].hidden = true;
        const double hidden = furnace("  hidden", camera, aim, angle, NAN, failed);
        failed += hidden != seen || !(seen > 0);
        printf("%s: hidden %.5f, seen %.5f%s\n", name, hidden, seen, hidden != seen || !(seen > 0) ? "  FAILED" : "");
    };
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}, {V(0, 2.2f, 0), 1, false, {lambert(0, 1)}, 1, 1,
        false, none}};
    twins("hidden emitter after a bounce", V(0, 0, 5), center, 0.1f, 1);
    camera_fog = {scaled(ONE, 0.3f), scaled(ONE, 0.3f)};
    scene = {{center, 10, true, {lambert(0, 0)}, 1, 1, false, none}, {V(0, 3, 0), 1, false, {lambert(0, 1)}, 1, 1,
        false, none}, {V(0, 3, 0), 1.5f, false, {dielectric(1)}, 1, 1, false, none}};
    twins("hidden emitter after fog", center, V(0, 0, 1), 0.1f, 1);
    camera_fog = none;
    scene = {{center, 2, false, {dielectric(1.5f)}, 1, 1, false, none}, {center, 1, false, {lambert(0, 1)}, 1, 1, false,
        none}};
    twins("hidden emitter through glass 1.5", V(0, 0, 5), center, 0.1f, 1);
    scene = {{center, 2, false, {dielectric(1)}, 1, 1, true, {scaled(ONE, 0.3f), scaled(ONE, 0.3f)}},
        {V(0, 3.5f, 0), 1, false, {lambert(0, 1)}, 1, 1, false, none}};
    twins("hidden emitter past fog in a clear shell", V(0, 0, 5), center, 0.1f, 1);
    scene = {{center, 2, false, {dielectric(1)}, 1, 1, false, none}, {center, 0.5f, false, {lambert(0, 1)}, 1, 1, false,
        none, true}, {V(0, 0, -1.3f), 0.5f, false, {lambert(0, 1)}, 1, 1, false, none}};
    {
        const V eye(0, 0, 5);
        const auto seen = [&](V dir) {
            const Hit hit = HookScene_traverseInstanceBVH_0(Ray{eye, dir}, true, 1e30f, true, NO_HIT, true);
            return Domain{eye, eye + scaled(dir, hit.distance), hit};
        };
        const Domain near = seen(V(0, 0, -1)), off = seen(V(sinf(0.02f), 0, -cosf(0.02f)));
        int lit = 0, back = 0;
        for (int i = 0; i < 4096; i++) {
            Reservoir path = {};
            path.seed = hash(3 * i + 2);
            Selection sel = {};
            sel.random_state = hash(3 * i + 3);
            walk_hook(near, path, false, 1, &sel);
            const Reservoir r = finalize(sel, 1);
            const Shift to = shift_hook(off, r);
            Reservoir moved = r;
            moved.f = to.f;
            const Shift home = shift_hook(near, moved);
            lit += r.w > 0;
            back += r.w > 0 && to.f.x > 0 && to.jac == 1 && home.jac == 1 && home.f.x == r.f.x && home.f.z == r.f.z;
        }
        const bool kept = lit > 256 && back == lit;
        failed += !kept;
        printf("replay past a hidden emitter: %d of %d paths there and back exactly%s\n", back, lit,
            kept ? "" : "  FAILED");
    }
    sun = slot_leaf = true;
    const float unslotted = lightPdf_0(ZERO, ZERO, ZERO, 0xFFFFFFFFu, SUN), slotted = lightPdf_0(ZERO, ZERO, ZERO, 0, SUN);
    sun = slot_leaf = false;
    failed += unslotted != 0 || !(slotted > 0);
    printf("light of no slot: density %g, the sun's %g%s\n", unslotted, slotted,
        unslotted != 0 || !(slotted > 0) ? "  FAILED" : "");
    failed += tracked_misfits > 0 || tracked == 0;
    printf("camera segments: %d misfits of %d tracked%s\n", tracked_misfits, tracked,
        tracked_misfits > 0 || tracked == 0 ? "  FAILED" : "");
    failed += shaded_misfits > 0;
    printf("shaded directions: %d misfits%s\n", shaded_misfits, shaded_misfits > 0 ? "  FAILED" : "");
    failed += escapes != 1 << 17 || escape_misfits > 0;
    printf("escape context: %d of %d escapes off the sphere's vertex, %d misfits%s\n", escapes, 1 << 17, escape_misfits,
        escapes != 1 << 17 || escape_misfits > 0 ? "  FAILED" : "");
    failed += misfits > 0 || segments == 0;
    printf("handed segments: %d misfits, %d medium vertices checked%s\n", misfits, segments,
        misfits > 0 || segments == 0 ? "  FAILED" : "");
    return failed;
}
