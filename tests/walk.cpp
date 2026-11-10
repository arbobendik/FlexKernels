// The walk itself on the CPU: flex-cuda-pt's ReSTIR variant, generating, over scenes of spheres its hooks give, no
// light in its light tree, under an environment map of 1 everywhere that light sampling draws (4 x 2 cells, uniform
// CDF). Furnaces of derived values, each within four standard errors (or 1e-4 where every path reads alike), its
// standard error below 0.01 so that no estimate blowing up passes on its spread:
// - a white Lambertian sphere returns all it receives: 1, with ReSTIR off too, where its selection only sums;
// - so does one covered at 0.3 (alpha coverage passes the rest through), while a black one covered at 0.3 lets
//   the sky through where both its faces leave the ray uncovered: 0.7^2;
// - a coat over glass, both smooth dielectrics, returns all: 1;
// - an index-matched sphere filled with a medium of albedo 1 returns all: 1;
// - a white sphere inside an index-matched shell returns all: 1, and so does one beside such a shell, whose sky
//   light passes it to the sphere's light sampling and its escapes alike;
// - a white sphere seen from inside a boundless absorber, scattering nothing, returns all it receives as the absorber
//   lets it through: exp(-e d) over the camera rays' distances d to the sphere;
// - inside a closed sphere of walls of albedo a emitting e inward: a e / (1 - a), as the walk leaves what the first
//   hit emits to the consumer;
// - from the centre of a white fog sphere of extinction s and radius 1, down, under a black sky, alone (bounces 0),
//   homogeneous or varying, ReSTIR on or off: a sun of irradiance 1 along -x scattered in on the way, (s / 4 pi)
//   int_0^1 exp(-s (t + sqrt(1 - t^2))) dt, and walls emitting 1 inward seen through it as the walk's glow, exp(-s);
// - paths of it that scattered on the camera's way, shifted into another pixel's domain and back: their integrand
//   exactly, at Jacobian 1 both ways; and with a bounce more, single and double scattering;
// - the sun scattered in from vertices nearer the fog's face than a surface's margin, their shadow rays meeting it.
// Printed: each furnace's reading against its value
#include <stdio.h>
#include <math.h>
#include <vector>
#include <initializer_list>
#include "pathtracer.cpp"

using V = Vector<float, 3>;
static const V ZERO(0, 0, 0), ONE(1, 1, 1);
static float dotv(V a, V b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V scaled(V a, float s) { return V(a.x * s, a.y * s, a.z * s); }
struct Shape { V center; float radius; bool inward; Material layer[2]; unsigned layers; float coverage; bool encloses;
    Medium volume; };
static std::vector<Shape> scene;
// Of the camera ray each walk starts with, as handed, and of the shadow rays of medium vertices where a furnace checks
// them, their segment's length against the distance from where it started
static V handed_direction;
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

// Past a surface's margin of 1e-4 when the ray leaves one, else (a medium vertex's) from its start
Hit HookScene_traverseInstanceBVH_0(Ray ray, bool, float max_len, bool surface) {
    Hit hit = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, max_len};
    const float near = surface ? 1e-4f : 0.0f;
    for (unsigned i = 0; i < scene.size(); i++) {
        const V oc = ray.origin - scene[i].center;
        const float b = dotv(oc, ray.unit_direction), c = dotv(oc, oc) - scene[i].radius * scene[i].radius;
        if (b * b - c < 0) continue;
        const float s = sqrtf(b * b - c), t = -b - s > near ? -b - s : -b + s;
        if (t > near && t < hit.distance) hit.instance_index = i, hit.distance = t;
    }
    return hit;
}
Surface HookScene_surfaceAtPath_0(Hit hit, V origin, uint32_t state, float, uint32_t layer, uint32_t, uint32_t) {
    const Shape& s = scene[hit.instance_index];
    const V n = scaled(origin - s.center, (s.inward ? -1 : 1) / s.radius);
    return Surface{n, n, 1e-4f, s.layer[layer], false, state, s.coverage, s.encloses, s.volume, 0xFFFFFFFFu};
}
Surface HookScene_surfaceAt_0(Hit hit, V origin, uint32_t state) {
    return HookScene_surfaceAtPath_0(hit, origin, state, 0, 0, 0, 0);
}
uint32_t HookScene_layers_0(Hit hit) { return scene[hit.instance_index].layers; }
// No light in the tree: a leaf of no importance, which lights no point and is no light's slot; or where a furnace sets
// it, a sun of irradiance 1 travelling -x: a delta light 1e4 along +x of intensity 1e8, the walk having no distant one
static bool sun = false;
static const V SUN(1e4f, 0, 0);
Vector<uint32_t, 4> HookScene_lightNode_0(uint32_t) { return Vector<uint32_t, 4>(sun ? 2 : 1, 0, 0, 0); }
uint32_t HookScene_lightSecond_0(uint32_t) { return 0; }
LightBounds HookScene_lightBounds_0(uint32_t) {
    return sun ? LightBounds{SUN, SUN, V(1, 0, 0), 1, -1} : LightBounds{ZERO, ZERO, V(0, 0, 1), 0, 1};
}
Vector<uint32_t, 4> HookScene_lightTrail_0(uint32_t) { return Vector<uint32_t, 4>(0, 0, 0, 0); }
uint32_t HookScene_lightSlot_0(Hit) { return 0; }
bool HookScene_slotLeaf_0(uint32_t, uint32_t, Vector<uint32_t, 4>) { return false; }
Light HookScene_light_0(uint32_t) { return Light{SUN, 0, ONE, 1e8f, 0}; }
uint32_t HookScene_triangleOffset_0(uint32_t) { return 0; }
Matrix<float, 3, 3> HookScene_worldTriangle_0(uint32_t, uint32_t) { return Matrix<float, 3, 3>(0.0f); }
V HookScene_calculatePointLightContrib_0(uint32_t) { return ZERO; }
V HookScene_hitPosition_0(Hit) { return ZERO; }
// Shadows pass index-matched clear surfaces alone, through media by their extinction
static V shadowThrough(Ray ray, float l, bool surface) {
    for (float along = 0;; surface = true) {
        const Hit hit = HookScene_traverseInstanceBVH_0(ray, false, l - along, surface);
        if (hit.instance_index == 0xFFFFFFFFu) return ONE;
        const Material& m = scene[hit.instance_index].layer[0];
        if (!(m.transmission == 1 && m.ior == 1 && scene[hit.instance_index].layers == 1)) return ZERO;
        along += hit.distance, ray.origin = ray.origin + scaled(ray.unit_direction, hit.distance);
    }
}
V HookScene_shadowTransmittance_0(Ray ray, float l) { return shadowThrough(ray, l, true); }
// the medium a shadow ray starts in filling it up to the first surface it meets
V HookScene_shadowTransmittanceIn_0(Ray ray, float l, V extinction, uint32_t, uint32_t, uint32_t, uint32_t,
    bool surface, float length, float) {
    const V from = ray.origin - segment_start;
    if (checking && !surface) segments++, misfits += fabsf(sqrtf(dotv(from, from)) - length) > 1e-6f;
    const float inside = fminf(HookScene_traverseInstanceBVH_0(ray, false, l, surface).distance, l);
    const V through = shadowThrough(ray, l, surface);
    return V(through.x * expf(-extinction.x * inside), through.y * expf(-extinction.y * inside),
        through.z * expf(-extinction.z * inside));
}
static uint32_t bounces = 64;
uint32_t HookScene_maxBounces_0() { return bounces; }
// The environment: 1 everywhere, or black where a furnace sets it, its 4 x 2 cells equally likely
static float sky = 1;
V HookScene_env_map_sample_0(V) { return scaled(ONE, sky); }
V HookScene_ambient_0() { return ONE; }
Vector<uint32_t, 2> HookScene_environmentMapSize_0() { return Vector<uint32_t, 2>(4, 2); }
Vector<uint32_t, 2> HookScene_environmentCdfSize_0() { return Vector<uint32_t, 2>(5, 2); }
Vector<float, 4> HookScene_environmentCdf_0(Vector<uint32_t, 2> cell) {
    return cell.x == 4 ? Vector<float, 4>((cell.y + 1) / 2.0f, 0.5f, 0, 0)
        : Vector<float, 4>((cell.x + 1) / 4.0f, 0.25f, 0, 0);
}
// The camera's medium: fog where a furnace sets it, else none; homogeneous, or varying of the same coefficients
static Medium camera_fog = {ZERO, ZERO};
static bool varying = false;
Medium HookScene_cameraMedium_0(V direction, float distance, uint32_t* filling) {
    handed_direction = direction, handed_distance = distance;
    *filling = varying ? 0 : 0xFFFFFFFFu;
    return camera_fog;
}
// The varying camera fog, tracked under its extinction: each tentative collision real, scattering by its albedo
float HookScene_majorant_0(uint32_t) { return camera_fog.extinction.x; }
float HookScene_trackMedium_0(uint32_t, V, V, float distance, uint32_t* state, V* weight, V*, V* scatter, V* extinction,
    uint32_t, uint32_t) {
    const Random u = pcg(*state);
    *state = u.state;
    const float along = -logf(1 - u.value) / camera_fog.extinction.x;
    if (along < distance) {
        *weight = scaled(*weight, camera_fog.scatter.x / camera_fog.extinction.x);
        *scatter = camera_fog.scatter, *extinction = camera_fog.extinction;
    }
    return along < distance ? along : 2 * distance;
}

// Mean and standard error of what paths from the camera bring back, toward the sphere aim, within angle of it
static bool summing = false, seen = false;
static void furnace(const char* name, V camera, V aim, float angle, double truth, int& failed, float absorbs = 0) {
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
        const Hit hit = HookScene_traverseInstanceBVH_0(Ray{camera, dir}, true, 1e30f, true);
        Domain dom = {camera, camera + scaled(dir, hit.distance), hit};
        Reservoir path = {};
        path.seed = hash(3 * i + 2);
        Selection sel = {};
        sel.random_state = hash(3 * i + 3);
        sel.sums = summing;
        segment_start = camera;
        walk_hook(dom, path, false, 1, &sel);
        // As the walk derives them from the domain's points, to float precision
        misfits += dotv(handed_direction, dir) < 1 - 1e-6f
            || fabsf(handed_distance - hit.distance) > 1e-5f * hit.distance;
        const double y = sel.color.x + (seen ? sel.glow.x : 0);
        through += exp(-absorbs * hit.distance);
        sum += y, sum2 += y * y;
    }
    const double mean = sum / N, se = sqrt(fmax(sum2 / N - mean * mean, 0) / N);
    truth *= through / N;
    const bool ok = fabs(mean - truth) < fmax(4 * se, 1e-4) && se < 0.01;
    failed += !ok;
    printf("%-28s %.5f +- %.5f of %.5f%s\n", name, mean, se, truth, ok ? "" : "  FAILED");
}

int main() {
    int failed = 0;
    const V camera(0, 0, 3), center(0, 0, 0);
    const Medium none = {ZERO, ZERO}, fog = {scaled(ONE, 2), scaled(ONE, 2)};
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    furnace("white sphere", camera, center, 0.3f, 1, failed);
    summing = true;
    furnace("white sphere, ReSTIR off", camera, center, 0.3f, 1, failed);
    summing = false;
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
    // From the centre of a white fog sphere of radius 1 straight down, under a black sky, alone (bounces 0): the sun
    // scattered in along the ray, and walls emitting 1 inward seen through the fog, read with the walk's glow
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
    // With a bounce more, single and double scattering, as light sampled at scattering vertices, a delta light the
    // phase function never samples, keeps its whole weight: 0.0123111 + 0.001953, flexkernels' Monte Carlo the double
    bounces = 1, sun = true, seen = false, varying = summing = false;
    camera_fog = {scaled(ONE, 0.2f), scaled(ONE, 0.2f)};
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, camera_fog}};
    furnace("sun in fog 0.2, bounces 1", center, V(0, 0, -1), 0, 0.014264, failed);
    // From 0.5e-4 inside the fog sphere's face toward the sun, of extinction 10, down: the camera ray leaves it after
    // 0.01, each scattering vertex within 0.5e-4 of that face, which the sun's shadow ray, of no margin, meets:
    // (s / 4 pi) int_0^T exp(-s (t + sqrt(1 - t^2) - x)) dt at the camera's x in float, by scipy's quad
    bounces = 0;
    camera_fog = {scaled(ONE, 10), scaled(ONE, 10)};
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, camera_fog}};
    checking = true;
    furnace("sun in fog by its face", V(1 - 0.5e-4f, 0, 0), V(1 - 0.5e-4f, 0, -1), 0, 0.00757074921909657, failed);
    checking = false;
    // Replay in the fog: paths the sun reaches after scattering on the camera's way, shifted into a pixel 0.1 off and
    // back, read their own integrand again at Jacobian 1 both ways, the shift the identity on their random numbers
    sun = true, varying = summing = false, camera_fog = {scaled(ONE, 0.5f), scaled(ONE, 0.5f)};
    scene = {{center, 1, false, {dielectric(1)}, 1, 1, true, camera_fog}};
    const auto domain = [&](V dir) {
        const Hit hit = HookScene_traverseInstanceBVH_0(Ray{center, dir}, true, 1e30f, true);
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
    // Every walk handed the camera ray's direction and distance, and each medium vertex its segment's length
    failed += misfits > 0 || segments == 0;
    printf("handed segments: %d misfits, %d medium vertices checked%s\n", misfits, segments,
        misfits > 0 || segments == 0 ? "  FAILED" : "");
    return failed;
}
