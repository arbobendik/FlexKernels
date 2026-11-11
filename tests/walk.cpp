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
    Medium volume; bool hidden = false; float tilt = 0, offset = 1e-4f; V axis = V(0, 0, 1); float cap = -2;
    bool hair = false; };
static std::vector<Shape> scene;
static const Hit NO_HIT = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, 0};
// The camera's medium: fog where a furnace sets it, else none; homogeneous, or varying of the same coefficients
static Medium camera_fog = {ZERO, ZERO};
// Of the camera ray each walk starts with, its distance as handed, and of the shadow rays of medium vertices where a
// furnace checks them, their segment's length against the distance from where it started
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
// The hit each straight pass leaves, as the walk hands it over, against the one it shaded last
static Hit last_shaded = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, 0};
static int skips = 0, skip_misfits = 0, face_skips = 0;
// and the point it was shaded at, which the pass starts from, with no lift, off a layer of index 1
static V last_point;
static float last_ior = 1;
// Past shapes hidden from the camera while the ray sees straight from it, as flex-cuda-pt's traversal passes them
Hit HookScene_traverseInstanceBVH_0(Ray ray, bool, float max_len, bool surface, Hit left, bool viewed) {
    if (left.instance_index != 0xFFFFFFFFu)
        skips++, skip_misfits += left.instance_index != last_shaded.instance_index
            || left.distance != last_shaded.distance
            || ray.origin.x != last_point.x || ray.origin.y != last_point.y || ray.origin.z != last_point.z
            || last_ior != 1;
    face_skips += left.instance_index != 0xFFFFFFFFu && !surface;  // From an opaque face, no margin, past its own
    Hit hit = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, max_len};
    const float near = surface ? 1e-4f : 0.0f;
    for (unsigned i = 0; i < scene.size(); i++) {
        if (viewed && scene[i].hidden) continue;
        const V oc = ray.origin - scene[i].center;
        // In double: a start offsets 1e-4 over a sphere of radius 1000, below float's resolution of |oc|^2
        const double ox = oc.x, oy = oc.y, oz = oc.z, r = scene[i].radius;
        const double b = ox * ray.unit_direction.x + oy * ray.unit_direction.y + oz * ray.unit_direction.z,
            c = (ox * ox + oy * oy + oz * oz) - r * r;
        if (b * b - c < 0) continue;
        // Past the start's own shape where left names it, as past its own triangle: its far side alone, if ahead; of a
        // cap, the sphere's points within cap's cosine of its axis alone
        const bool own = left.instance_index == i;
        const double s = sqrt(b * b - c);
        for (const float t : {float(-b - s), float(-b + s)}) {
            const V on = ray.origin + scaled(ray.unit_direction, t) - scene[i].center;
            if (!(t > near) || (own && !(t > 1e-4f * scene[i].radius))
                || dotv(on, scene[i].axis) < scene[i].cap * scene[i].radius) continue;
            if (t < hit.distance) hit.instance_index = i, hit.distance = t;
            break;
        }
    }
    return hit;
}
// The ray's direction each surface is shaded by: at the first hit, outside fog, the camera ray's own, bit for bit
static V handed_direction;
static int shaded_misfits = 0;
Surface HookScene_surfaceAtPath_0(Hit hit, V origin, uint32_t state, float, uint32_t layer, uint32_t depth, uint32_t,
    V dir) {
    last_shaded = hit, last_point = origin, last_ior = scene[hit.instance_index].layer[layer].ior;
    shaded_misfits += depth == 0 && camera_fog.extinction.x == 0
        && (dir.x != handed_direction.x || dir.y != handed_direction.y || dir.z != handed_direction.z);
    const Shape& s = scene[hit.instance_index];
    const V n = scaled(origin - s.center, (s.inward ? -1 : 1) / s.radius);
    // Its smooth normal tilted toward +x by tilt where a furnace sets it, its offset the consumer's start height
    const V x = V(1, 0, 0) - scaled(n, n.x);
    const V smooth = s.tilt == 0 ? n : scaled(n, cosf(s.tilt)) + scaled(x, sinf(s.tilt) / sqrtf(dotv(x, x)));
    Surface surface = {smooth, n, s.offset, s.layer[layer], false, state, s.coverage, s.encloses, s.volume,
        0xFFFFFFFFu};
    if (s.hair) surface.hair = V(0, 0, 1), surface.geometry_offset = 0;  // A fiber along z, from its vertex
    return surface;
}
Surface HookScene_surfaceAt_0(Hit hit, V origin, uint32_t state) {
    return HookScene_surfaceAtPath_0(hit, origin, state, 0, 0, 1, 0, ZERO);
}
// Hair as an isotropic fiber, a stand-in for flex-cuda-pt's baked far field: albedo times tint over the sphere, of
// density 1 / (4 pi), its throughput the albedo; directions it samples uniform over the sphere
static int hair_connects = 0;
SampleBSDF HookScene_connectHair_0(V, V albedo, V tint, V in_dir, V out_dir) {
    hair_connects++;  // Forward a refraction, as flex-cuda-pt labels hair's, else a reflection (2)
    return SampleBSDF{out_dir, V(albedo.x * tint.x, albedo.y * tint.y, albedo.z * tint.z), 0, false,
        dotv(out_dir, in_dir) > 0 ? 1u : 2u, 0.25f / 3.14159265f};
}
SampleBSDF HookScene_sampleHair_0(V hair, V albedo, V tint, V in_dir, uint32_t state) {
    const Random u = pcg(state), v = pcg(u.state);
    const float z = 1 - 2 * u.value, r = sqrtf(fmaxf(0, 1 - z * z)), phi = 6.2831853f * v.value;
    SampleBSDF sampled = HookScene_connectHair_0(hair, albedo, tint, in_dir, V(r * cosf(phi), r * sinf(phi), z));
    sampled.random_state = v.state;
    return sampled;
}
// No emitting triangle: its lights are delta ones
Surface HookScene_lightSurfaceAt_0(Hit hit, V point, uint32_t state, V, uint32_t, float) {
    return HookScene_surfaceAt_0(hit, point, state);
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
// Each slot the leaf it reaches where a check sets it
static bool slot_leaf = false;
bool HookScene_slotLeaf_0(uint32_t, uint32_t, Vector<uint32_t, 4>) { return slot_leaf; }
Light HookScene_light_0(uint32_t) { return Light{SUN, 0, ONE, 1e8f, 0}; }
uint32_t HookScene_triangleOffset_0(uint32_t) { return 0; }
Matrix<float, 3, 3> HookScene_worldTriangle_0(uint32_t, uint32_t) { return Matrix<float, 3, 3>(0.0f); }
V HookScene_calculatePointLightContrib_0(uint32_t) { return ZERO; }
V HookScene_hitPosition_0(Hit) { return ZERO; }
// Shadows pass index-matched clear surfaces, and the uncovered share of the others, as flex-cuda-pt's do, through
// media by their extinction
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
V HookScene_shadowTransmittance_0(Ray ray, float l) { return shadowThrough(ray, l, true); }
// the medium a shadow ray starts in filling it up to the first surface it meets
V HookScene_shadowTransmittanceIn_0(Ray ray, float l, V extinction, uint32_t, uint32_t, uint32_t, uint32_t,
    bool surface, float length, float, Hit left) {
    const V from = ray.origin - segment_start;
    if (checking && !surface) segments++, misfits += fabsf(sqrtf(dotv(from, from)) - length) > 1e-6f;
    const float inside = fminf(HookScene_traverseInstanceBVH_0(ray, false, l, surface, left, false).distance, l);
    const V through = shadowThrough(ray, l, surface, left);
    return V(through.x * expf(-extinction.x * inside), through.y * expf(-extinction.y * inside),
        through.z * expf(-extinction.z * inside));
}
static uint32_t bounces = 64;
uint32_t HookScene_maxBounces_0() { return bounces; }
// The environment: 1 everywhere, or black where a furnace sets it, its 4 x 2 cells equally likely
static float sky = 1;
// The environment's Light Path context where a furnace checks it: off a convex white sphere each path's escape leaves
// its one vertex, of depth 0, by the diffuse lobe (0); the sky's light samples hand none (0 and LOBE_NONE, 3)
static bool escapes_checked = false;
static int escapes = 0, escape_misfits = 0;
// Lighting only from below a plane of normal below where a furnace sets it
static V below(0, 0, 0);
V HookScene_env_map_sample_0(V dir, uint32_t depth, uint32_t lobe) {
    if (escapes_checked) escapes += depth == 0 && lobe == 0, escape_misfits += depth != 0 || lobe != 0 && lobe != 3;
    if (dotv(below, below) > 0 && !(dotv(dir, below) < 0)) return ZERO;
    return scaled(ONE, sky);
}
V HookScene_ambient_0() { return ONE; }
Vector<uint32_t, 2> HookScene_environmentMapSize_0() { return Vector<uint32_t, 2>(4, 2); }
// Of no luminance distribution (1 x 1) where a furnace sets it, as flex-cuda-pt's world before it has one, its reads
// counted
static bool cdf = true;
static int cdf_reads = 0;
Vector<uint32_t, 2> HookScene_environmentCdfSize_0() { return Vector<uint32_t, 2>(cdf ? 5 : 1, cdf ? 2 : 1); }
Vector<float, 4> HookScene_environmentCdf_0(Vector<uint32_t, 2> cell) {
    cdf_reads++;
    return cell.x == 4 ? Vector<float, 4>((cell.y + 1) / 2.0f, 0.5f, 0, 0)
        : Vector<float, 4>((cell.x + 1) / 4.0f, 0.25f, 0, 0);
}
// The camera's medium, as below
static bool varying = false;
Medium HookScene_cameraMedium_0(V direction, float distance, uint32_t* filling) {
    handed_direction = direction, handed_distance = distance;
    *filling = varying ? 0 : 0xFFFFFFFFu;
    return camera_fog;
}
// The varying camera fog, tracked under its extinction: each tentative collision real, scattering by its albedo
float HookScene_majorant_0(uint32_t) { return camera_fog.extinction.x; }
// Of each walk, the camera's own segment flagged as the camera's, its first tracked, and none after it
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

// Mean and standard error of what paths from the camera bring back, toward the sphere aim, within angle of it
static bool summing = false, seen = false;
// Unchecked where truth is NAN; the mean returned
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
        // As the walk derives them from the domain's points, to float precision
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
    // A sky mapped but of no luminance distribution isn't light sampled: escapes alone, unweighted, bring it all
    cdf = false, cdf_reads = 0;
    furnace("white sphere, sky unsampled", camera, center, 0.3f, 1, failed);
    failed += cdf_reads > 0;
    printf("sky unsampled: %d reads of its distribution%s\n", cdf_reads, cdf_reads > 0 ? "  FAILED" : "");
    cdf = true;
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
    // Its faces turned out, the camera inside: opaque walls face the ray and emit on both sides, as flex-cuda-pt's do,
    // so it reads as with them turned in, while the walk takes no wall's inside for its own (flexkernels' row)
    scene = {{center, 1, false, {lambert(0.5f, 1)}, 1, 1, false, none}};
    furnace("inside walls faced out", center, V(0, 0, 1), 3.14159265f, 1, failed);
    summing = true;
    furnace("inside walls faced out, ReSTIR off", center, V(0, 0, 1), 3.14159265f, 1, failed);
    summing = false;
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
    // Seen through a black shell covered at 0.5 around an emitter of 1, the pass through its uncovered half a vertex of
    // its own: with no bounce the walk ends there, reading 0; with one it reaches the emitter, 0.5. Each such pass hands
    // the trace the hit it leaves, which flex-cuda-pt's traversal skips
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
    // Inside a black shell covered at 0.5, under a sky of 1, either way the shell's mesh turns its faces: a white
    // sphere, which half the camera rays reach and which sees half the sky through the shell, reads 0.25; an index-
    // matched ball absorbing half per unit length keeps 0.5^chord between the shell's two passes, 0.25 E[0.5^(2 sqrt(1
    // - (5 sin t)^2))] over the camera's cone by scipy's quad. And that ball covered at 0.5 itself, with no shell, its
    // faces out: both its shares pass at index 1, so its inside stays its own, 4 times that (flexkernels' probe); its
    // faces turned in would make it a body outside them, as flex-cuda-pt fills the back of faces
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
    // Hidden from the camera, as flex-cuda-pt's veil test: an emitter of 1 inside each of these, seen straight through
    // it under a black sky, reads 0 hidden, the camera's rays passing it while they see straight, and visible 1, 1, 1
    // and e^-0.6: a clear shell of index 1, a cutout shell (coverage 0), a box of a medium of density 0, and one
    // absorbing over the 0.6 between its face and the emitter's; ReSTIR off and on
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
    // Hidden only while seen straight: an emitter lights a white sphere the camera sees, or, inside a clear shell of
    // index 1, fog the camera looks through, exactly as when it isn't hidden, the camera never seeing it straight
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
    // And through glass of index 1.5, which bends the camera's rays; and from fog inside a clear shell, entered by a
    // straight pass, onto an emitter outside it off the camera's rays (flexkernels' rows)
    scene = {{center, 2, false, {dielectric(1.5f)}, 1, 1, false, none}, {center, 1, false, {lambert(0, 1)}, 1, 1, false,
        none}};
    twins("hidden emitter through glass 1.5", V(0, 0, 5), center, 0.1f, 1);
    scene = {{center, 2, false, {dielectric(1)}, 1, 1, true, {scaled(ONE, 0.3f), scaled(ONE, 0.3f)}},
        {V(0, 3.5f, 0), 1, false, {lambert(0, 1)}, 1, 1, false, none}};
    twins("hidden emitter past fog in a clear shell", V(0, 0, 5), center, 0.1f, 1);
    // Replay past a hidden emitter: paths through a clear shell, past it, to an emitter behind it, shifted into a
    // pixel 0.02 off and back, read their own integrand again at Jacobian 1 both ways, with no state for it
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
    // A light shell, as flex-cuda-pt's sphere lights: clear at index 1, glowing L / 2 = 0.5 on each side, under a black
    // sky; from outside a ray meets it twice, reading L = 1, and from inside once, reading 0.5, the walk taking the
    // shell's far side as the camera's first hit's emission alike, from either side; ReSTIR on and off
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
    // flex-cuda-pt's start rule off opaque surfaces: a cap of a huge white sphere, locally a plane, its smooth normals
    // tilted 60 degrees toward the sun, which lies 40 degrees below its face there, above the tilted normal (in the
    // wedge); black sky, the sun alone, one bounce. Nothing lights the face: 0, its start lifted along the face by the
    // offset (from no margin its shadow ray meets the face), or on it (no light below the face, its own triangle
    // skipped)
    bounces = 1, sky = 0, sun = true, camera_fog = none, seen = false;
    {
        const float R = 1000;
        const V g(cosf(2.26893f), 0, sinf(2.26893f));  // 130 degrees from the sun's +x
        for (const float offset : {1e-4f, 0.0f}) {
            scene = {{scaled(g, -R), R, false, {lambert(1, 0)}, 1, 1, false, none, false, 1.0471976f, offset, g,
                0.999f}};
            furnace(offset > 0 ? "sun in the wedge, lifted" : "sun in the wedge, on the face", scaled(g, 5), ZERO,
                0.01f, 0, failed);
        }
    }
    // The same cap under a sky lighting it only from below its face: nothing reaches its top, by the sky's light
    // samples (which see below the face only past it) or by bounces into the wedge (which meet the face again);
    // sampled and unsampled
    sun = false, sky = 1, bounces = 4;
    {
        const V g(cosf(2.26893f), 0, sinf(2.26893f));
        below = g;
        for (const bool sampled : {true, false}) {
            cdf = sampled;
            scene = {{scaled(g, -1000), 1000, false, {lambert(1, 0)}, 1, 1, false, none, false, 1.0471976f, 0, g,
                0.999f}};
            furnace(sampled ? "sky below the face" : "sky below the face, unsampled", scaled(g, 5), ZERO, 0.01f, 0,
                failed);
        }
        cdf = true, below = ZERO;
    }
    // A white sphere starting its rays on its face, from no margin past its own triangle, under a sky of 1: 1, each
    // such ray handing the hit it leaves
    bounces = 64, sky = 1, sun = false, face_skips = 0;
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none, false, 0, 0}};
    furnace("white sphere from its face", camera, center, 0.3f, 1, failed);
    summing = true;
    furnace("white sphere from its face, ReSTIR off", camera, center, 0.3f, 1, failed);
    summing = false;
    failed += face_skips == 0;
    printf("starts on the face: %d past their own hit%s\n", face_skips, face_skips == 0 ? "  FAILED" : "");
    // Hair, a white sphere of isotropic fiber under a sky of 1, returns all it receives, ReSTIR on and off; each of its
    // rays, bounced or light sampled, leaves from its vertex past its own segment. The sky unsampled, as flex-cuda-pt's
    // (its light samples at hair come once flex-cuda-pt samples the sky)
    bounces = 64, sky = 1, sun = false, camera_fog = none, seen = false, face_skips = 0, hair_connects = 0, cdf = false;
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
    scene[0].hair = true;
    furnace("white hair", camera, center, 0.3f, 1, failed);
    summing = true;
    furnace("white hair, ReSTIR off", camera, center, 0.3f, 1, failed);
    summing = false;
    // The sky light sampled too, a light both sampled and met: hair's light samples weighed against its escapes
    cdf = true;
    furnace("white hair, sky sampled", camera, center, 0.3f, 1, failed);
    cdf = false;
    failed += face_skips == 0 || hair_connects == 0;
    printf("hair: %d rays past their own segment, %d connections%s\n", face_skips, hair_connects,
        face_skips == 0 || hair_connects == 0 ? "  FAILED" : "");
    // Hair lit by the sun all around it, as flex-cuda-pt samples light at strands: its light samples through its far
    // field, f E = 1 / 4 pi, whichever way its smooth normal points (toward the sun, or 2 radians away)
    bounces = 0, sky = 0, sun = true;
    for (const float tilt : {0.0f, -2.0f}) {
        const V p(0.70710678f, 0, 0.70710678f);
        scene = {{ZERO, 1, false, {lambert(1, 0)}, 1, 1, false, none}};
        scene[0].hair = true, scene[0].tilt = tilt;
        furnace(tilt == 0 ? "hair under the sun, its normal toward it" : "hair under the sun, its normal away",
            scaled(p, 5), p, 0.001f, 0.25 / 3.14159265, failed);
    }
    bounces = 64, sun = false;
    // Hidden only while seen straight: a hidden emitter seen past hair, which scatters every ray, reads as when seen
    sky = 0;
    scene = {{center, 1, false, {lambert(1, 0)}, 1, 1, false, none}, {V(0, 0, -2.5f), 1, false, {lambert(0, 1)}, 1, 1,
        false, none}};
    scene[0].hair = true;
    twins("hidden emitter past hair", camera, center, 0.1f, 1);
    sky = 1, cdf = true;
    // A light of no slot, as flex-cuda-pt's strands, has no light sampling density, where the sun's slot reaches its
    // leaf (a point: infinite)
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
    // Every walk handed the camera ray's direction and distance, and each medium vertex its segment's length
    failed += misfits > 0 || segments == 0;
    printf("handed segments: %d misfits, %d medium vertices checked%s\n", misfits, segments,
        misfits > 0 || segments == 0 ? "  FAILED" : "");
    return failed;
}
