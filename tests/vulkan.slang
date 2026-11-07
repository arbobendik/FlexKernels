// The module imported into a compute shader compiled to SPIR-V, as flex-cuda-pt's Vulkan renderer imports it, calling
// what that calls
import pathtracer;

RWStructuredBuffer<Reservoir> reservoirs;

#ifdef FK_RESTIR
// A scene of each hook's simplest answer from its arguments, for the walk's code to reach SPIR-V whole: a light BVH of a
// root and two leaves, a 4 x 4 environment, four bounces
struct TestScene : IScene {
    Hit traverseInstanceBVH(Ray ray, bool consider_point_lights, float max_len) {
        return Hit(ray.origin.xy, ray.unit_direction.x > 0.0f ? 0u : UINT_MAX, uint(consider_point_lights), 0u, max_len * 0.5f);
    }
    bool shadowTraverseInstanceBVH(Ray ray, float l, bool two_sided) { return two_sided && l > ray.origin.x; }
    Surface surfaceAt(Hit hit, float3 origin, uint init_random_state) {
        return Surface(normalize(origin), float3(0.0f, 0.0f, 1.0f), 1e-4f, Material(origin, float3(hit.uv, 0.0f), 0.5f,
            0.0f, hit.distance, 1.5f, origin), hit.is_point_light != 0u, init_random_state + 1u);
    }
    float3 hitPosition(Hit hit) { return float3(hit.uv, hit.distance); }
    float3x3 worldTriangle(uint instance_index, uint triangle_index) {
        return float3x3(float3(float(instance_index)), float3(1.0f, 0.0f, 0.0f), float3(0.0f, float(triangle_index), 1.0f));
    }
    LightBounds lightBounds(uint n) { return LightBounds(float3(-1.0f), float3(float(n)), float3(0.0f, 0.0f, 1.0f), 1.0f, 0.5f); }
    uint4 lightNode(uint n) { return uint4(n == 0u ? 0u : n, n, 0u, 0u); }
    uint lightSecond(uint n) { return 2u; }
    uint lightSlot(Hit hit) { return hit.triangle_index; }
    uint4 lightTrail(uint j) { return uint4(j, 0u, 1u + j % 2u, 0u); }
    bool slotLeaf(uint n, uint j, uint4 trail_texel) { return n == trail_texel.z; }
    Light light(uint index) { return Light(float3(float(index)), 0.0f, float3(1.0f), 1.0f, 0.1f); }
    uint triangleOffset(uint instance_index) { return instance_index; }
    float3 calculatePointLightContrib(uint index) { return float3(float(index)); }
    float3 env_map_sample(float3 dir) { return abs(dir); }
    float4 environmentCdf(uint2 cell) { return float4(float(cell.x + 1u) / 5.0f, 0.25f, 0.0f, 0.0f); }
    uint2 environmentCdfSize() { return uint2(5u, 4u); }
    uint2 environmentMapSize() { return uint2(4u, 4u); }
    float3 ambient() { return float3(0.1f); }
    uint maxBounces() { return 4u; }
    uint2 renderSize() { return uint2(64u, 48u); }
    uint frame() { return 7u; }
    float3x3 viewMatrix() { return float3x3(float3(1.0f, 0.0f, 0.0f), float3(0.0f, 1.0f, 0.0f), float3(0.0f, 0.0f, 1.0f)); }
    float3 cameraPosition() { return float3(0.0f, 0.0f, -2.0f); }
    float3x3 prevViewMatrix() { return viewMatrix(); }
    float3 prevCameraPosition() { return float3(0.1f, 0.0f, -2.0f); }
    int4 pairing(int2 texel, uint t) { return int4(texel.yx - int2(int(t)), 0, 0); }
    uint4 reservoirPrevious(int2 q, uint layer) { return uint4(uint(q.x), layer, 0u, asuint(float(q.y))); }
    Domain previousDomain(int2 q) { return Domain(float3(0.0f), float3(float2(q), 1.0f), Hit(float2(0.5f), uint(q.x), uint(q.y), 0u, 1.0f)); }
}
#endif

#ifdef FK_RESTIR
float walkOver(Domain dom, Reservoir r) {
    TestScene scene;
    Selection sel = {};
    const Shift shifted = walk(scene, dom, r, (r.path & 1u) != 0u, r.c, sel);
    const int2 p = int2(int(r.seed % 64u), int(r.seed / 64u % 48u));
    const int2 q = temporalNeighbor(scene, p, dom) + partner(scene, p, r.path % 3u);
    return shifted.f.x * shifted.jac + sel.w_sum + shift(scene, dom, r).jac * float(sameDomain(dom, dom)) + float(q.x * q.y);
}
#endif

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 id: SV_DispatchThreadID) {
    const Reservoir r = reservoirs[id.x];
    const float3 n = normalize(mix(r.dir, r.radiance, sign(r.w)));
    const Material material = Material(r.f, r.radiance, r.w, r.c, r.jac, 1.5f, r.dir);
    const SampleBSDF sampled = sampleBSDF(r.dir, n, material, 1.0f, 1.5f, stream(r.seed, id.x), float2(0.0f));
    const SampleBSDF connected = connectBSDF(r.dir, sampled.unit_direction, n, material, 1.0f, 1.5f, sampled.lobe,
        pcg(hash(r.path)).state);
    Selection sel = {};
    offer(sel, withEnd(r, 1u, 2u, connected.throughput * smithG1(r.w, fresnel(r.c, 1.0f, 1.5f))),
        safeDivide(r.f, tangentToWorldNormalMap(r.radiance, float3x3(r.dir, r.f, n))));
    offerShifted(sel, r, Shift(r.f, rgb_to_greyscale(r.radiance)), r.c);
    // A step down the light tree, as light sampling and its density take one
    const LightBounds bounds = LightBounds(r.dir, r.radiance, n, r.w, r.c);
    float pick = r.jac, probability = 1.0f;
    const uint child = pickChild(bounds, bounds, r.f, n, pick, probability);
#ifdef FK_RESTIR
    // The walk's records: a domain at the reservoir's hit and the previous vertex of the reconnection criteria
    const Domain dom = Domain(r.dir, r.radiance, Hit(r.f.xy, r.rc.x, r.rc.y, END_POINT, r.w));
    const Vertex v = Vertex(r.w > 0.0f, LOBE_REFRACT, r.c, dot(dom.x0, dom.x1), (r.path >> PATH_INSIDE & 1u) != 0u);
#endif
    reservoirs[id.x] = finalize(sel, r.c * childShare(bounds, bounds, r.f, n, child) * solidAngle(probability, r.f, n)
        + importance(bounds, r.f, n) * sine(pick) * powerHeuristic(r.w, r.jac) * float(samplesLights(material))
#ifdef FK_RESTIR
        + v.pdf * v.cos * dom.hit.distance * float(v.rough != v.inside)
        // The walk over the test scene, generating or replaying by the path's lowest bit
        + walkOver(dom, r)
#endif
        );
}
