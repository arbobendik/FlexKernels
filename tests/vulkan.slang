// The module imported into a compute shader compiled to SPIR-V, as flex-cuda-pt's Vulkan renderer imports it, calling
// what that calls
import pathtracer;

RWStructuredBuffer<Reservoir> reservoirs;
#ifdef FK_RESTIR
RWStructuredBuffer<uint> queue;
#endif

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
    uint restirNeighbours() { return 3u; }
    Reservoir loadReservoirPrevious(int2 q) { return reservoirs[uint(q.x)]; }
    Reservoir loadReservoirInitial(int2 p) { return reservoirs[uint(p.y)]; }
    Reservoir loadReservoirTemporal(int2 p) { return reservoirs[uint(p.x + p.y)]; }
    bool storedDomainInitial(int2 p, out Domain dom) { dom = previousDomain(p); return p.x > 0; }
    bool storedDomainTemporal(int2 p, out Domain dom) { dom = previousDomain(p.yx); return p.y > 0; }
    uint queueCountAdd(uint bin, uint jobs) { uint before; InterlockedAdd(queue[bin], jobs, before); return before; }
    uint queueCountLoad(uint bin) { return queue[bin]; }
    uint queueCursorAdd(uint bin, uint jobs) { uint before; InterlockedAdd(queue[40u + bin], jobs, before); return before; }
    void queueJobStore(uint index, uint job) { queue[80u + index] = job; }
    void queueDispatchStore(uint x, uint y, uint z) { queue[0] = x + y + z; }
    uint queuedShifts(uint index) { return queue[index]; }
    bool currentDomain(int2 p, out Domain dom) { dom = previousDomain(p + 1); return p.y > 1; }
    uint samples() { return 2u; }
    uint restirDecorrelation() { return 1u; }
    uint isTemporal() { return 1u; }
    float3x3 invViewMatrix() { return viewMatrix(); }
    void storeReservoirInitial(int2 p, Reservoir r, Hit x1) { reservoirs[uint(p.x)] = r; queue[2] = x1.triangle_index; }
    void storeReservoirTemporal(int2 p, Reservoir r, Hit x1) { reservoirs[uint(p.y)] = r; queue[1] = x1.instance_index; }
    void storeReservoirPrevious(int2 p, Reservoir r, Hit x1) { reservoirs[uint(p.x + p.y)] = r; queue[0] = x1.instance_index; }
    void storePreviousLayer(int2 p, uint layer, uint4 value) { queue[uint(p.x) + layer] = value.x + value.y; }
    uint4 duplication(int2 q) { return uint4(queue[uint(q.x)]); }
    void storeDuplication(int2 p, uint4 value) { queue[uint(p.y)] = value.x; }
    uint4 temporalShift(int2 p, uint layer) { return uint4(queue[uint(p.x) + layer]); }
    void storeTemporalShift(int2 p, uint layer, uint4 value) { queue[uint(p.y) + layer] = value.w; }
    uint4 shiftData(int2 p, uint layer) { return uint4(queue[uint(p.y) + layer]); }
    void storeShiftData(int2 p, uint layer, uint4 value) { queue[uint(p.x) + layer] = value.z; }
    uint4 reservoirTemporal(int2 q, uint layer) { return uint4(queue[uint(q.x) + layer]); }
    void storeColor(int2 p, uint layer, float4 color) { queue[uint(p.x) + layer] = asuint(color.x + color.w); }
}
#endif

#ifdef FK_RESTIR
float walkOver(Domain dom, Reservoir r) {
    TestScene scene;
    Selection sel = {};
    const Shift shifted = walk(scene, dom, r, (r.path & 1u) != 0u, r.c, sel);
    const int2 p = int2(int(r.seed % 64u), int(r.seed / 64u % 48u));
    const int2 q = temporalNeighbor(scene, p, dom) + partner(scene, p, r.path % 3u);
    const uint[3] bins = temporalBins(scene, p);
    const uint[3] spatial = spatialBins(scene, q);
    return shifted.f.x * shifted.jac + sel.w_sum + shift(scene, dom, r).jac * float(sameDomain(dom, dom)) + float(q.x * q.y)
        + float(bins[0] + bins[1] + spatial[2] + shiftBin(r));
}

// The shift queue's rounds over the test scene: counting, queueing and taking the workgroup's jobs
void queueRound(uint3 id, uint local, uint3 group) {
    TestScene scene;
    const uint[3] bins = spatialBins(scene, int2(id.xy));
    countShifts(scene, bins, local);
    queueShifts(scene, int2(id.xy), bins, id, local);
    queue[3u + id.x] = queuedShift(scene, group, local);
}
#endif

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 id: SV_DispatchThreadID, uint local: SV_GroupIndex, uint3 group: SV_GroupID) {
#ifdef FK_RESTIR
    queueRound(id, local, group);
#endif
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
