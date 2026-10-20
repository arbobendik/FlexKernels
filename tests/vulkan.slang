import pathtracer;

RWStructuredBuffer<Reservoir> reservoirs;

[shader("compute")]
[numthreads(64, 1, 1)]
void main(uint3 id: SV_DispatchThreadID) {
    const Reservoir r = reservoirs[id.x];
    const float3 n = normalize(mix(r.dir, r.radiance, sign(r.w)));
    const Material material = Material(r.f, r.radiance, r.w, r.c, r.jac, 1.5f, r.dir);
    const SampleBSDF sampled = sampleBSDF(r.dir, n, material, 1.0f, 1.5f, stream(r.seed, id.x), float2(0.0f));
    const float3 connected = BSDF(r.dir, sampled.unit_direction, n, n, material, 1.0f, 1.5f, pcg(hash(r.path)).state);
    Selection sel = {};
    offer(sel, withEnd(r, 1u, 2u, connected * G1(r.w, fresnel(r.c, 1.0f, 1.5f))),
        safeDivide(r.f, tangentToWorldNormalMap(r.radiance, float3x3(r.dir, r.f, n))));
    offerShifted(sel, r, Shift(r.f, rgb_to_greyscale(r.radiance)), r.c);
    const LightBounds bounds = LightBounds(r.dir, r.radiance, n, r.w, r.c);
    float pick = r.jac, probability = 1.0f;
    const uint child = pickChild(bounds, bounds, r.f, n, pick, probability);
    reservoirs[id.x] = finalize(sel, r.c * childShare(bounds, bounds, r.f, n, child) * solidAngle(probability, r.f, n)
        + importance(bounds, r.f, n) * sine(pick) * powerHeuristic(r.w, r.jac)
        * float(neeDecision(material, dot(n, r.dir), 1.0f, material.ior)));
}
