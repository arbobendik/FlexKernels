// The walk itself on the CPU: flex-cuda-pt's ReSTIR variant, generating, over scenes of spheres its hooks give, no
// light in its light tree, under an environment map of 1 everywhere that light sampling draws (4 x 2 cells, uniform
// CDF). Furnaces of derived values, each within four standard errors (or 1e-4 where every path reads alike), its
// standard error below 0.01 so that no estimate blowing up passes on its spread:
// - a white Lambertian sphere returns all it receives: 1;
// - so does one covered at 0.3 (alpha coverage passes the rest through), while a black one covered at 0.3 lets
//   the sky through where both its faces leave the ray uncovered: 0.7^2;
// - a coat over glass, both smooth dielectrics, returns all: 1;
// - an index-matched sphere filled with a medium of albedo 1 returns all: 1;
// - a white sphere inside an index-matched shell returns all: 1, and so does one beside such a shell, whose sky
//   light passes it to the sphere's light sampling and its escapes alike;
// - inside a closed sphere of walls of albedo a emitting e inward: a e / (1 - a), as the walk leaves what the first
//   hit emits to the consumer.
// Printed: each furnace's reading against its value
#include <stdio.h>
#include <math.h>
#include <vector>
#include "pathtracer.cpp"

using V = Vector<float, 3>;
static const V ZERO(0, 0, 0), ONE(1, 1, 1);
static float dotv(V a, V b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
static V scaled(V a, float s) { return V(a.x * s, a.y * s, a.z * s); }
struct Shape { V center; float radius; bool inward; Material layer[2]; unsigned layers; float coverage; bool encloses;
    Medium volume; };
static std::vector<Shape> scene;
static Material lambert(float albedo, float emits) {
    return Material{scaled(ONE, albedo), scaled(ONE, emits), 1, 0, 0, 1, ONE, ONE, 1, ZERO, ZERO, 0.5f, 0, 0, ZERO};
}
static Material dielectric(float ior) {
    return Material{ONE, ZERO, 0, 0, 1, ior, ONE, ONE, 1, ZERO, ZERO, 0.5f, 0, 0, ZERO};
}

Hit HookScene_traverseInstanceBVH_0(Ray ray, bool, float max_len) {
    Hit hit = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, max_len};
    for (unsigned i = 0; i < scene.size(); i++) {
        const V oc = ray.origin - scene[i].center;
        const float b = dotv(oc, ray.unit_direction), c = dotv(oc, oc) - scene[i].radius * scene[i].radius;
        if (b * b - c < 0) continue;
        const float s = sqrtf(b * b - c), t = -b - s > 1e-4f ? -b - s : -b + s;
        if (t > 1e-4f && t < hit.distance) hit.instance_index = i, hit.distance = t;
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
// No light in the tree: a leaf of no importance, which lights no point and is no light's slot
Vector<uint32_t, 4> HookScene_lightNode_0(uint32_t) { return Vector<uint32_t, 4>(1, 0, 0, 0); }
uint32_t HookScene_lightSecond_0(uint32_t) { return 0; }
LightBounds HookScene_lightBounds_0(uint32_t) { return LightBounds{ZERO, ZERO, V(0, 0, 1), 0, 1}; }
Vector<uint32_t, 4> HookScene_lightTrail_0(uint32_t) { return Vector<uint32_t, 4>(0, 0, 0, 0); }
uint32_t HookScene_lightSlot_0(Hit) { return 0; }
bool HookScene_slotLeaf_0(uint32_t, uint32_t, Vector<uint32_t, 4>) { return false; }
Light HookScene_light_0(uint32_t) { return Light{}; }
uint32_t HookScene_triangleOffset_0(uint32_t) { return 0; }
Matrix<float, 3, 3> HookScene_worldTriangle_0(uint32_t, uint32_t) { return Matrix<float, 3, 3>(0.0f); }
V HookScene_calculatePointLightContrib_0(uint32_t) { return ZERO; }
V HookScene_hitPosition_0(Hit) { return ZERO; }
// Shadows pass index-matched clear surfaces alone, through media by their extinction
V HookScene_shadowTransmittance_0(Ray ray, float l) {
    for (float along = 0;;) {
        const Hit hit = HookScene_traverseInstanceBVH_0(ray, false, l - along);
        if (hit.instance_index == 0xFFFFFFFFu) return ONE;
        const Material& m = scene[hit.instance_index].layer[0];
        if (!(m.transmission == 1 && m.ior == 1 && scene[hit.instance_index].layers == 1)) return ZERO;
        along += hit.distance, ray.origin = ray.origin + scaled(ray.unit_direction, hit.distance);
    }
}
V HookScene_shadowTransmittanceIn_0(Ray ray, float l, V extinction, uint32_t, uint32_t, uint32_t, uint32_t) {
    return HookScene_shadowTransmittance_0(ray, l);
}
uint32_t HookScene_maxBounces_0() { return 64; }
// The environment: 1 everywhere, its 4 x 2 cells equally likely
V HookScene_env_map_sample_0(V) { return ONE; }
V HookScene_ambient_0() { return ONE; }
Vector<uint32_t, 2> HookScene_environmentMapSize_0() { return Vector<uint32_t, 2>(4, 2); }
Vector<uint32_t, 2> HookScene_environmentCdfSize_0() { return Vector<uint32_t, 2>(5, 2); }
Vector<float, 4> HookScene_environmentCdf_0(Vector<uint32_t, 2> cell) {
    return cell.x == 4 ? Vector<float, 4>((cell.y + 1) / 2.0f, 0.5f, 0, 0)
        : Vector<float, 4>((cell.x + 1) / 4.0f, 0.25f, 0, 0);
}
// The camera's medium: boundless fog where a furnace sets it, else none
static Medium camera_fog = {ZERO, ZERO};
Medium HookScene_cameraMedium_0(uint32_t* filling) {
    *filling = 0xFFFFFFFFu;
    return camera_fog;
}
V HookScene_passMedium_0(uint32_t, V, V, float, uint32_t*, V*) { return ONE; }
// Varying media: none here
float HookScene_majorant_0(uint32_t) { return 0; }
float HookScene_trackMedium_0(uint32_t, V, V, float distance, uint32_t*, V*, V*, V*, V*, uint32_t, uint32_t) {
    return 2 * distance;
}

// Mean and standard error of what paths from the camera bring back, toward the sphere aim, within angle of it
static void furnace(const char* name, V camera, V aim, float angle, double truth, int& failed) {
    const int N = 1 << 17;
    double sum = 0, sum2 = 0;
    for (int i = 0; i < N; i++) {
        Random u = pcg(hash(3 * i + 1)), v = pcg(u.state);
        const float z = 1 - u.value * (1 - cosf(angle)), r = sqrtf(fmaxf(0, 1 - z * z)), phi = 6.2831853f * v.value;
        const V w = scaled(aim - camera, 1 / sqrtf(dotv(aim - camera, aim - camera)));
        const V t = fabsf(w.x) < 0.9f ? V(1, 0, 0) : V(0, 1, 0), a = scaled(t - scaled(w, dotv(t, w)),
            1 / sqrtf(1 - dotv(t, w) * dotv(t, w)));
        const V b(w.y * a.z - w.z * a.y, w.z * a.x - w.x * a.z, w.x * a.y - w.y * a.x);
        const V dir = scaled(a, r * cosf(phi)) + scaled(b, r * sinf(phi)) + scaled(w, z);
        const Hit hit = HookScene_traverseInstanceBVH_0(Ray{camera, dir}, true, 1e30f);
        Domain dom = {camera, camera + scaled(dir, hit.distance), hit};
        Reservoir path = {};
        path.seed = hash(3 * i + 2);
        Selection sel = {};
        sel.random_state = hash(3 * i + 3);
        walk_hook(dom, path, false, 1, &sel);
        const double y = sel.color.x;
        sum += y, sum2 += y * y;
    }
    const double mean = sum / N, se = sqrt(fmax(sum2 / N - mean * mean, 0) / N);
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
    scene = {{center, 1, true, {lambert(0.5f, 1)}, 1, 1, false, none}};
    furnace("inside walls of albedo 0.5", center, V(0, 0, 1), 3.14159265f, 1, failed);
    return failed;
}
