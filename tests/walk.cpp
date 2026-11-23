#include <stdio.h>
#include <math.h>
#include <string.h>
#include <vector>
#include <initializer_list>
#include "pathtracer.cpp"
#include "terms.h"

using V = Vector<float, 3>;
static const V ZERO(0, 0, 0), ONE(1, 1, 1);
static float dotv(V a, V b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V scaled(V a, float s) { return V(a.x * s, a.y * s, a.z * s); }
struct Shape { V center; float radius; bool inward; Material layer[2]; unsigned layers; float coverage; bool encloses;
    Medium volume; bool hidden = false; bool hair = false; float tilt = 0; V axis = V(0, 0, 1); float cap = -2; };
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
static int skips = 0, skip_misfits = 0, own_skips = 0;
static V last_point;
static float last_ior = 1;
Hit HookScene_traverseInstanceBVH_0(Ray ray, bool, float max_len, bool surface, Hit left, bool viewed) {
    if (left.instance_index != 0xFFFFFFFFu)
        skips++, skip_misfits += left.instance_index != last_shaded.instance_index
            || left.distance != last_shaded.distance
            || ray.origin.x != last_point.x || ray.origin.y != last_point.y || ray.origin.z != last_point.z
            || last_ior != 1;
    own_skips += left.instance_index != 0xFFFFFFFFu && !surface;
    Hit hit = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, max_len};
    const float near = surface ? 1e-4f : 0.0f;
    for (unsigned i = 0; i < scene.size(); i++) {
        if (viewed && scene[i].hidden) continue;
        // In double: |oc|^2 of a radius 1000 sphere loses a 1e-4 offset in float
        const double ox = double(ray.origin.x) - scene[i].center.x, oy = double(ray.origin.y) - scene[i].center.y,
            oz = double(ray.origin.z) - scene[i].center.z, r = scene[i].radius;
        const double b = ox * ray.unit_direction.x + oy * ray.unit_direction.y + oz * ray.unit_direction.z,
            c = (ox * ox + oy * oy + oz * oz) - r * r;
        if (b * b - c < 0) continue;
        const bool own = left.instance_index == i;
        const double s = sqrt(b * b - c);
        for (const float t : {float(-b - s), float(-b + s)}) {
            const V on = ray.origin + scaled(ray.unit_direction, t) - scene[i].center;
            if (!(t > near) || (own && !(t > 1e-4f * scene[i].radius))
                || dotv(on, scene[i].axis) < scene[i].cap * scene[i].radius) continue;
            // The point's polar and azimuthal angles about the center as its uv
            if (t < hit.distance) hit.instance_index = i, hit.distance = t,
                hit.uv = Vector<float, 2>(acosf(fmaxf(-1, fminf(1, on.z / scene[i].radius))), atan2f(on.y, on.x));
            break;
        }
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
    // Smooth normal tilted toward +x by tilt
    const V x = V(1, 0, 0) - scaled(n, n.x);
    const V smooth = s.tilt == 0 ? n : scaled(n, cosf(s.tilt)) + scaled(x, sinf(s.tilt) / sqrtf(dotv(x, x)));
    Surface surface = {smooth, n, 1e-4f, s.layer[layer], false, state, s.coverage, s.encloses, s.volume, 0xFFFFFFFFu};
    if (s.hair) surface.hair = V(0, 0, 1), surface.geometry_offset = 0;
    return surface;
}
Surface HookScene_surfaceAt_0(Hit hit, V origin, uint32_t state) {
    return HookScene_surfaceAtPath_0(hit, origin, state, 0, 0, 1, 0, ZERO);
}
// Hair as an isotropic fiber: f = albedo * tint / (4 * PI), PDF = 1 / (4 * PI)
static int hair_connects = 0, light_connects = 0;
static bool hair_sampling = false;
SampleBSDF HookScene_connectHair_0(V, V albedo, V tint, V in_dir, V out_dir) {
    hair_connects++, light_connects += !hair_sampling;
    return SampleBSDF{out_dir, V(albedo.x * tint.x, albedo.y * tint.y, albedo.z * tint.z), 0, false,
        dotv(out_dir, in_dir) > 0 ? 1u : 2u, 0.25f / 3.14159265f};
}
SampleBSDF HookScene_sampleHair_0(V hair, V albedo, V tint, V in_dir, uint32_t state) {
    const Random u = pcg(state), v = pcg(u.state);
    const float z = 1 - 2 * u.value, r = sqrtf(fmaxf(0, 1 - z * z)), phi = 6.2831853f * v.value;
    hair_sampling = true;
    SampleBSDF sampled = HookScene_connectHair_0(hair, albedo, tint, in_dir, V(r * cosf(phi), r * sinf(phi), z));
    hair_sampling = false;
    sampled.random_state = v.state;
    return sampled;
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
V HookScene_hitPosition_0(Hit hit) {
    const Shape& s = scene[hit.instance_index];
    const V on(sinf(hit.uv.x) * cosf(hit.uv.y), sinf(hit.uv.x) * sinf(hit.uv.y), cosf(hit.uv.x));
    return s.center + scaled(on, s.radius);
}
// Shadows pass index-matched clear surfaces and the uncovered share of others, media by exp(-extinction * d)
static V shadowThrough(Ray ray, float l, bool surface, Hit left = NO_HIT) {
    float share = 1;
    for (float along = 0;; surface = true, left = NO_HIT) {
        const Hit hit = HookScene_traverseInstanceBVH_0(ray, false, l - along, surface, left, false);
        if (hit.instance_index == 0xFFFFFFFFu) return scaled(ONE, share);
        const Material& m = scene[hit.instance_index].layer[0];
        if (!(m.transmission == 1 && m.ior == 1 && scene[hit.instance_index].layers == 1))
            share *= 1 - scene[hit.instance_index].coverage;
        if (!(share > 0)) return ZERO;
        along += hit.distance, ray.origin = ray.origin + scaled(ray.unit_direction, hit.distance);
    }
}
// A sky drawn from cell (1, 0) of its 4 x 2 alone, its draws' directions held to that cell, z up
static bool one_cell = false;
static int cell_draws = 0, cell_misses = 0;
V HookScene_shadowTransmittanceIn_0(Ray ray, float l, V extinction, uint32_t, uint32_t, uint32_t, uint32_t,
    bool surface, float length, float, Hit left, Hit) {
    const V from = ray.origin - segment_start;
    if (checking && !surface) segments++, misfits += fabsf(sqrtf(dotv(from, from)) - length) > 1e-6f;
    if (one_cell && !(l < 4294967296.0f)) {
        // s = atan2(-y, x) / (2 * PI) + 0.5 in [0.25, 0.5), t = acos(z) / PI < 0.5
        const float s = atan2f(-ray.unit_direction.y, ray.unit_direction.x) / 6.2831853f + 0.5f;
        cell_draws++, cell_misses += !(s >= 0.25f && s < 0.5f && acosf(ray.unit_direction.z) / 3.14159265f < 0.5f);
    }
    const Hit first = HookScene_traverseInstanceBVH_0(ray, false, l, surface, left, false);
    // A ray toward the sky past every surface leaves its medium at once, as the walk's escapes do
    const float inside = first.instance_index == 0xFFFFFFFFu && !(l < 4294967296.0f) ? 0 : fminf(first.distance, l);
    const V through = shadowThrough(ray, l, surface, left);
    return V(through.x * expf(-extinction.x * inside), through.y * expf(-extinction.y * inside),
        through.z * expf(-extinction.z * inside));
}
static uint32_t bounces = 64;
uint32_t HookScene_maxBounces_0() { return bounces; }
static float sky = 1;
static bool escapes_checked = false;
static int escapes = 0, escape_misfits = 0;
static V below(0, 0, 0);
// A world reading the ray's kind: half as bright to rays leaving by any lobe but the diffuse one
static bool lobe_world = false;
bool HookScene_worldReadsPath_0() { return lobe_world; }
V HookScene_env_map_sample_0(V dir, uint32_t depth, uint32_t lobe) {
    if (escapes_checked) escapes += depth == 0 && lobe == 0, escape_misfits += depth != 0 || lobe != 0 && lobe != 3;
    return scaled(ONE, (dotv(below, below) > 0 && !(dotv(dir, below) < 0) ? 0 : sky) * (lobe_world && lobe != 0 ? 0.5f : 1));
}
V HookScene_ambient_0() { return ONE; }
Vector<uint32_t, 2> HookScene_environmentMapSize_0() { return Vector<uint32_t, 2>(4, 2); }
static bool cdf = true;
static int cdf_reads = 0;
Vector<uint32_t, 2> HookScene_environmentCdfSize_0() { return Vector<uint32_t, 2>(cdf ? 5 : 1, cdf ? 2 : 1); }
Vector<float, 4> HookScene_environmentCdf_0(Vector<uint32_t, 2> cell) {
    cdf_reads++;
    if (one_cell)
        return cell.x == 4 ? Vector<float, 4>(1, cell.y == 0, 0, 0) : Vector<float, 4>(cell.x >= 1, cell.x == 1, 0, 0);
    return cell.x == 4 ? Vector<float, 4>((cell.y + 1) / 2.0f, 0.5f, 0, 0)
        : Vector<float, 4>((cell.x + 1) / 4.0f, 0.25f, 0, 0);
}
static bool varying = false;
Medium HookScene_cameraMedium_0(V direction, float distance, uint32_t* filling) {
    handed_direction = direction, handed_distance = distance;
    *filling = varying ? 0 : 0xFFFFFFFFu;
    return camera_fog;
}
static int majorants_of_none = 0;
bool HookScene_varyingUsed_0() { return true; }
bool HookScene_hairUsed_0() { return true; }
bool HookScene_dispersionUsed_0() { return true; }
bool HookScene_shadowFirst_0() { return true; }
static Medium world = {ZERO, ZERO};
// Asked of the face being left, the one shaded last
static int outside_asked = 0, outside_misfits = 0;
Medium HookScene_outsideMedium_0(Hit hit) {
    outside_asked++, outside_misfits += hit.instance_index != last_shaded.instance_index;
    return world;
}
float HookScene_majorant_0(uint32_t filling) {
    majorants_of_none += filling == 0xFFFFFFFFu;
    return camera_fog.extinction.x;
}
static int tracked = 0, tracked_misfits = 0, walk_tracks = 0;
float HookScene_trackMedium_0(uint32_t, V, V, float distance, uint32_t* state, V* weight, V*, V* scatter, V* extinction,
    float* g, uint32_t, uint32_t, bool camera) {
    tracked++, tracked_misfits += camera != (walk_tracks++ == 0);
    const Random u = pcg(*state);
    *state = u.state;
    const float along = -logf(1 - u.value) / camera_fog.extinction.x;
    if (along < distance) {
        *weight = scaled(*weight, camera_fog.scatter.x / camera_fog.extinction.x);
        *scatter = camera_fog.scatter, *extinction = camera_fog.extinction, *g = camera_fog.g;
    }
    return along < distance ? along : 2 * distance;
}

static bool summing = false, seen = false;
// The pixel by its resampled sample, f * W after finalize, in place of the offered sum
static bool resampled = false;
// Standard error of the last furnace's mean
static double furnace_se = 0;
// Channel the furnace reads
static int furnace_channel = 0;
// The digest of the walk drawing by noise address, no tensor bound, for two diffuse spheres under a sky of 0.7
static const uint64_t UNMARKED_DIGEST = 0x4c66b20f61d8da8full;
// FNV-1a over each path's colour, kept sample and stored radiance, bit for bit
static uint64_t digest = 0;
static void digested(float x) {
    uint32_t bits;
    memcpy(&bits, &x, 4);
    digest = (digest ^ bits) * 1099511628211ull;
}
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
        const Reservoir kept = finalize(sel, 1);
        for (int k = 0; k < 3; k++) digested(sel.color[k]), digested(kept.f[k]), digested(sel.r.radiance[k]);
        digested(kept.w);
        const double y = resampled ? kept.f[furnace_channel] * kept.w
            : sel.color[furnace_channel] + (seen ? sel.glow[furnace_channel] : 0);
        through += exp(-absorbs * hit.distance);
        sum += y, sum2 += y * y;
    }
    const double mean = sum / N, se = sqrt(fmax(sum2 / N - mean * mean, 0) / N);
    furnace_se = se;
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
    {
        // A world reading the ray's kind lights a glossy sphere alike through its sky samples and its escapes
        lobe_world = true;
        scene[0].layer[0] = Material{ONE, ZERO, 0.4f, 0, 0, 1.5f, ONE, ONE, 1, ZERO, ZERO, 0.5f, 0, 0, ZERO};
        const double sampled = furnace("glossy sphere, world by ray kind, sky sampled", camera, center, 0.3f, NAN, failed),
            sampled_se = furnace_se;
        cdf = false;
        const double escaped = furnace("  sky unsampled", camera, center, 0.3f, NAN, failed);
        const bool alike = fabs(sampled - escaped) < 4 * hypot(sampled_se, furnace_se);
        failed += !alike;
        printf("world by ray kind: sampled and escaped %s%s\n", alike ? "agree" : "differ", alike ? "" : "  FAILED");
        // A world reading no Light Path keeps main's walk bit for bit, its stored sky radiance the world times the
        // transmittance: two diffuse spheres side by side under a sky of 0.7, sampled
        cdf = true, lobe_world = false, sky = 0.7f, digest = 1469598103934665603ull;
        scene[0].layer[0] = lambert(0.8f, 0);
        scene.push_back({V(1.5f, 0, 0), 0.6f, false, {lambert(0.8f, 0)}, 1, 1, false, none});
        furnace("two diffuse spheres, sky 0.7", camera, center, 0.3f, NAN, failed);
        scene.pop_back();
        const bool kept_main = digest == UNMARKED_DIGEST;
        failed += !kept_main;
        printf("world reading no Light Path: walk %s main's (digest %016llx)%s\n", kept_main ? "equals" : "differs from",
            (unsigned long long)digest, kept_main ? "" : "  FAILED");
        sky = 1, scene[0].layer[0] = lambert(1, 0);
    }
    summing = true;
    furnace("white sphere, ReSTIR off", camera, center, 0.3f, 1, failed);
    {
        // White and coloured metal by their rebounces, limited per view: never above what they receive (1 and 4 standard
        // errors) and not below the values measured with the limit, less 0.002 and 4 standard errors
        const float ROUGHNESS[3] = {0.25f, 0.5f, 1};
        const float COLOR[3] = {0.9f, 0.5f, 0.2f};
        const double LOWER[3][4] = {{0.9941, 0.8953, 0.4973, 0.1989}, {0.9936, 0.8903, 0.4738, 0.1825},
            {0.9160, 0.7175, 0.2543, 0.0800}};
        int off = 0;
        for (int k = 0; k < 3; k++) for (int c = 0; c < 4; c++) {
            const V albedo = c == 0 ? ONE : V(COLOR[0], COLOR[1], COLOR[2]);
            scene[0].layer[0] = Material{albedo, ZERO, ROUGHNESS[k], 1, 0, 1.5f, ONE, ONE, 1, ZERO, ZERO, 0.5f, 0, 0,
                ZERO};
            furnace_channel = c == 0 ? 0 : c - 1;
            char name[64];
            snprintf(name, sizeof name, "  metal %s r%g channel %d", c == 0 ? "white" : "coloured", ROUGHNESS[k],
                furnace_channel);
            const double mean = furnace(name, camera, center, 0.3f, NAN, failed);
            off += mean > 1 + 4 * furnace_se || mean < LOWER[k][c] - 0.002 - 4 * furnace_se;
        }
        furnace_channel = 0, scene[0].layer[0] = lambert(1, 0);
        failed += off > 0;
        printf("metal rebounces: %d of 12 rows above 1 or below their measured value%s\n", off, off > 0 ? "  FAILED" : "");
    }
    // A white sheen over it drawn as its own lobe, reconnected and replayed by ReSTIR
    scene[0].layer[0].sheen = ONE, scene[0].layer[0].sheen_roughness = 0.5f;
    furnace("white sheen, ReSTIR off", camera, center, 0.3f, 1, failed);
    summing = false;
    furnace("white sheen", camera, center, 0.3f, 1, failed);
    scene[0].layer[0] = lambert(1, 0);
    scene[0].coverage = 0.3f;
    furnace("white sphere covered at 0.3", camera, center, 0.3f, 1, failed);
    scene[0].layer[0] = lambert(0, 0);
    furnace("black sphere covered at 0.3", camera, center, 0.3f, 0.49, failed);
    scene = {{center, 1, false, {dielectric(1.5f), dielectric(1.5f)}, 2, 1, false, none}};
    furnace("coat over glass", camera, center, 0.3f, 1, failed);
    {
        // The coat lobe against the exported layer of the same coat, tinted (0.9, 0.6, 0.3) over glass 1.5: the blue
        // channel seen straight on (cosine 1) and at the rim (cosine 0.19); a rough 2.0 coat over 1.5 glass returns
        // all it receives once the light it traps inside has the bounces to leave
        Material layer = dielectric(1.5f), lobe = dielectric(1.5f);
        layer.albedo = V(0.9f, 0.6f, 0.3f);
        lobe.coat = 1, lobe.coat_roughness = 0, lobe.coat_ior = 1.5f, lobe.coat_tint = layer.albedo;
        furnace_channel = 2;
        for (const float rim : {0.0f, 1.04f}) {
            scene = {{center, 1, false, {layer, dielectric(1.5f)}, 2, 1, false, none}};
            const double layered = furnace("tinted coat over glass, layer", camera, V(rim, 0, 0), 0.002f, NAN, failed),
                layered_se = furnace_se;
            scene = {{center, 1, false, {lobe}, 1, 1, false, none}};
            const double lobed = furnace("  coat lobe", camera, V(rim, 0, 0), 0.002f, NAN, failed);
            const bool near = fabs(lobed - layered) < fmax(4 * hypot(layered_se, furnace_se), 0.01);
            failed += !near;
            printf("tinted coat over glass at %s: lobe %.4f, layer %.4f%s\n", rim > 0 ? "the rim" : "the center",
                lobed, layered, near ? "" : "  FAILED");
        }
        furnace_channel = 0;
        lobe.coat_tint = ONE, lobe.coat_roughness = 0.3f, lobe.coat_ior = 2.0f;
        scene = {{center, 1, false, {lobe}, 1, 1, false, none}};
        bounces = 1024;
        furnace("rough coat 2.0 over glass 1.5", camera, center, 0.3f, 1, failed);
        bounces = 64;
    }
    // Each wavelength's weights integrate to white: a dispersive glass in the white sky keeps 1 in red, the channel
    // with the most negative weight
    Material dispersive = dielectric(1.5f);
    dispersive.dispersion = 0.2f;
    scene = {{center, 1, false, {dispersive}, 1, 1, false, none}};
    furnace("dispersive glass", camera, center, 0.3f, 1, failed);
    summing = true;
    furnace("dispersive glass, ReSTIR off", camera, center, 0.3f, 1, failed);
    summing = false;
    // Rough over a red ball, offers of different colours along a path: the resampled f * W against the summed offers
    scene[0].layer[0].roughness = 0.3f;
    Material red = lambert(1, 0);
    red.albedo = V(0.8f, 0.2f, 0.05f);
    scene.push_back({center, 0.5f, false, {red}, 1, 1, false, none});
    summing = true;
    const double summed = furnace("dispersive glass on red, summed", camera, center, 0.3f, NAN, failed);
    const double summed_se = furnace_se;
    summing = false, resampled = true;
    const double chosen = furnace("  resampled", camera, center, 0.3f, NAN, failed);
    resampled = false;
    const bool agree = fabs(chosen - summed) < 4 * sqrt(summed_se * summed_se + furnace_se * furnace_se);
    failed += !agree;
    printf("dispersive glass on red: resampled %.5f, summed %.5f%s\n", chosen, summed, agree ? "" : "  FAILED");
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, fog}};
    furnace("medium of albedo 1", camera, center, 0.3f, 1, failed);
    scene[0].volume.g = 0.8f;
    furnace("medium of albedo 1 scattering forward", camera, center, 0.3f, 1, failed);
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, false, none}, {center, 0.5f, false, {lambert(1, 0)}, 1, 1, false,
        none}};
    furnace("white sphere in a shell", camera, center, 0.15f, 1, failed);
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}, {V(0, 0, 3.2f), 2, false, {dielectric(1)}, 1, 1,
        false, none}};
    furnace("white sphere beside a shell", V(2.2f, 0, 0.6f), V(0, 0, 0.6f), 0.1f, 1, failed);
    // Clear shell of radius 1 about the camera, absorbing outside medium, walls emitting 1 at radius 10: exp(-0.1 * 9)
    world = {ZERO, scaled(ONE, 0.1f)}, sky = 0;
    scene = {{center, 10, true, {lambert(0, 1)}, 1, 1, false, none},
        {center, 1, false, {dielectric(1)}, 1, 1, true, none}};
    furnace("walls past a shell, outside absorbing", center, V(0, 0, 1), 3.14159265f, exp(-0.9), failed);
    world = none, sky = 1;
    failed += outside_asked == 0 || outside_misfits > 0;
    printf("outside medium: %d asked, %d off the face left%s\n", outside_asked, outside_misfits,
        outside_asked == 0 || outside_misfits > 0 ? "  FAILED" : "");
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    camera_fog = {ZERO, scaled(ONE, 0.5f)};
    furnace("white sphere in an absorber", camera, center, 0.3f, 1, failed, 0.5f);
    camera_fog = none;
    scene = {{center, 1, true, {lambert(0.5f, 1)}, 1, 1, false, none}};
    furnace("inside walls of albedo 0.5", center, V(0, 0, 1), 3.14159265f, 1, failed);
    scene = {{center, 1, false, {lambert(0.5f, 1)}, 1, 1, false, none}};
    furnace("inside walls faced out", center, V(0, 0, 1), 3.14159265f, 1, failed);
    summing = true;
    furnace("inside walls faced out, ReSTIR off", center, V(0, 0, 1), 3.14159265f, 1, failed);
    summing = false;
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
    // Light shell glowing L / 2 on each side: L = 1 from outside, 0.5 from inside
    bounces = 4, sky = 0, sun = false, camera_fog = none, seen = true;
    for (int restir = 0; restir < 2; restir++) {
        summing = !restir;
        Material glow = dielectric(1);
        glow.emissive = scaled(ONE, 0.5f);
        scene = {{center, 1, false, {glow}, 1, 1, false, none}};
        furnace(restir ? "light shell from outside" : "light shell from outside, ReSTIR off", V(0, 0, 5), center, 0, 1,
            failed);
        furnace(restir ? "light shell from inside" : "light shell from inside, ReSTIR off", center, V(0, 0, 1), 0, 0.5,
            failed);
    }
    summing = seen = false;
    // Light from below a face never reaches it: 0
    for (const float degrees : {0.0f, 15.0f, 30.0f, 50.0f, 60.0f, 75.0f}) {
        const float tilt = degrees / 57.29578f;
        const V g(-sinf(tilt / 2), 0, cosf(tilt / 2));
        char name[64];
        scene = {{scaled(g, -1000), 1000, false, {lambert(1, 0)}, 1, 1, false, none}};
        scene[0].tilt = tilt, scene[0].axis = g, scene[0].cap = 0.999f;
        bounces = 1, sky = 0, sun = true;
        snprintf(name, sizeof name, "sun in the wedge, %g deg", degrees);
        furnace(name, scaled(g, 5), ZERO, 0.01f, 0, failed);
        sun = false, sky = 1, bounces = 4, below = g;
        for (const bool sampled : {true, false}) {
            cdf = sampled;
            snprintf(name, sizeof name, "sky below the face, %g deg%s", degrees, sampled ? "" : ", unsampled");
            furnace(name, scaled(g, 5), ZERO, 0.01f, 0, failed);
        }
        below = ZERO, cdf = true, bounces = 64;
    }
    sky = 1;
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    scene[0].tilt = 1.2566371f;
    furnace("white sphere, smooth normals tilted 72 deg", camera, center, 0.3f, 1, failed);
    bounces = 64, sky = 1, sun = false, camera_fog = none, seen = false, own_skips = 0, hair_connects = 0, cdf = false;
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    scene[0].hair = true;
    furnace("white hair", camera, center, 0.3f, 1, failed);
    summing = true;
    furnace("white hair, ReSTIR off", camera, center, 0.3f, 1, failed);
    summing = false;
    failed += light_connects != 0;
    printf("hair under no light: %d light samples connected%s\n", light_connects,
        light_connects != 0 ? "  FAILED" : "");
    cdf = true;
    furnace("white hair, sky sampled", camera, center, 0.3f, 1, failed);
    cdf = false;
    failed += own_skips == 0 || hair_connects == 0;
    printf("hair: %d rays past their own segment, %d connections%s\n", own_skips, hair_connects,
        own_skips == 0 || hair_connects == 0 ? "  FAILED" : "");
    // Hair lit by the sun all around: f E = 1 / (4 * PI)
    bounces = 0, sky = 0, sun = true;
    for (const float tilt : {0.0f, -2.0f}) {
        const V p(0.70710678f, 0, 0.70710678f);
        scene = {{ZERO, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
        scene[0].hair = true, scene[0].tilt = tilt;
        furnace(tilt == 0 ? "hair under the sun, its normal toward it" : "hair under the sun, its normal away",
            scaled(p, 5), p, 0.001f, 0.25 / 3.14159265, failed);
    }
    // Rough glass cap lit from behind: its BSDF straight through times 1e8 / d^2
    {
        Material glass = dielectric(1.5f);
        glass.roughness = 0.6f;
        scene = {{ZERO, 1, false, {glass}, 1, 1, false, none}};
        scene[0].axis = V(-1, 0, 0), scene[0].cap = 0.95f;
        const V through(1, 0, 0), face(-1, 0, 0);
        const Vector<float, 2> eta = vertexEta(glass, 1);
        const double reach = 1e4 + 1 - 1e-4, f = faceBSDF(through, through, face, face, glass, eta.x, eta.y, 0).x;
        furnace("rough glass lit from behind", V(-5, 0, 0), V(-1, 0, 0), 0, f * 1e8 / (reach * reach), failed);
    }
    bounces = 64, sun = false;
    sky = 0;
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}, {V(0, 0, -2.5f), 1, false, {lambert(0, 1)}, 1, 1,
        false, none}};
    scene[0].hair = true;
    twins("hidden emitter past hair", camera, center, 0.1f, 1);
    sky = 1, cdf = true;
    sun = slot_leaf = true;
    const float unslotted = lightPdf_0(ZERO, ZERO, ZERO, 0xFFFFFFFFu, SUN), slotted = lightPdf_0(ZERO, ZERO, ZERO, 0, SUN);
    sun = slot_leaf = false;
    failed += unslotted != 0 || !(slotted > 0);
    printf("light of no slot: density %g, the sun's %g%s\n", unslotted, slotted,
        unslotted != 0 || !(slotted > 0) ? "  FAILED" : "");
    // Sky sampled = sky unsampled, in fog filling a clear shell and in the absorber behind a translucent face
    bounces = 64, sky = 1, sun = false, seen = false, summing = false, cdf = true;
    const auto sky_twins = [&](const char* name, V camera, V aim) {
        const double sampled = furnace("  sky sampled", camera, aim, 0.3f, NAN, failed), sampled_se = furnace_se;
        cdf = false;
        const double escaped = furnace("  sky unsampled", camera, aim, 0.3f, NAN, failed);
        cdf = true;
        const bool off = !(fabs(sampled - escaped) < 4 * sqrt(sampled_se * sampled_se + furnace_se * furnace_se));
        failed += off;
        printf("%s: sampled %.5f, unsampled %.5f%s\n", name, sampled, escaped, off ? "  FAILED" : "");
    };
    for (const float sigma : {0.0f, 0.5f}) {
        const Medium absorber = {ZERO, scaled(ONE, sigma)};
        char name[64];
        camera_fog = absorber;
        scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none},
            {center, 3, false, {dielectric(1)}, 1, 1, true, absorber}};
        snprintf(name, sizeof name, "sky in fog %.1f", sigma);
        sky_twins(name, V(0, 0, 2), center);
        camera_fog = none;
        Material translucent = lambert(0.5f, 0);
        translucent.translucent = scaled(ONE, 0.5f);
        scene = {{center, 1, false, {translucent}, 1, 0.5f, true, absorber}};
        snprintf(name, sizeof name, "sky into a translucent absorber %.1f", sigma);
        sky_twins(name, camera, center);
    }
    // White sphere under a sky of 1 drawn from one cell
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    one_cell = true;
    furnace("white sphere, sky of one cell", camera, center, 0.3f, 1, failed);
    one_cell = false;
    failed += cell_draws == 0 || cell_misses > 0;
    printf("sky of one cell: %d of %d draws off it%s\n", cell_misses, cell_draws,
        cell_draws == 0 || cell_misses > 0 ? "  FAILED" : "");
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
    failed += majorants_of_none != 0;
    printf("majorants asked of no medium: %d%s\n", majorants_of_none, majorants_of_none != 0 ? "  FAILED" : "");
    return failed;
}
