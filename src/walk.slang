// Path guiding and the bounce loop: the reservoirs, shifts and resampling weights of ReSTIR, the footprints and
// survival of its paths, and the light tree of light sampling, beside the BSDFs of pathtracer.slang
implementing pathtracer;

#ifdef FK_RESTIR
// ReSTIR PT Enhanced (Lin, Kettunen and Wyman 2026) on top of the path tracer above.
// Paths live in primary sample space, vertex b draws its random numbers from stream(seed, b).

// How a path ends: next event estimation, emissive surface, point light sphere, environment or environment by next event estimation
public static const uint END_NEE = 0u;
public static const uint END_EMIT = 1u;
public static const uint END_POINT = 2u;
public static const uint END_ENV = 3u;
public static const uint END_SKY = 4u;

// Reconnection vertex: none (pure random replay), triangle hit, NEE light vertex or environment direction
public static const uint RC_NONE = 0u;
public static const uint RC_SURFACE = 1u;
public static const uint RC_LIGHT = 2u;
public static const uint RC_ENV = 3u;
#endif

// Bit offsets of the packed path description
public static const uint PATH_END = 0u;
#ifdef FK_RESTIR
public static const uint PATH_K = 5u;
public static const uint PATH_RC = 10u;
#endif
public static const uint PATH_TYPE = 12u;
#ifdef FK_RESTIR
public static const uint PATH_LOBE_PREV = 15u;
public static const uint PATH_LOBE = 17u;
public static const uint PATH_NEE = 19u;
public static const uint PATH_INSIDE = 20u;

// Random streams besides the per vertex ones
public static const uint STREAM_NEE = 64u;
public static const uint STREAM_RR = 128u;
public static const uint STREAM_SELECT = 193u;
public static const uint STREAM_SKY = 256u;
#endif

// Target plumbing: flex-cuda-pt's own Reservoir (renderer.h), by which its host sizes its buffers, the struct for every
// other target; the shared code only copies rc, a Hit there, and never constructs a Reservoir
__target_intrinsic(cuda, "Reservoir")
__extern_cpp public struct Reservoir {
    __extern_cpp public uint seed;
    __extern_cpp public uint path;
    // Unbiased contribution weight and confidence
    __extern_cpp public float w;
    __extern_cpp public float c;
    // Integrand of the sample in the owning pixel
    __extern_cpp public float3 f;
    // Source densities p(x_k-1 -> x_k) G(x_k-1 -> x_k) p(x_k -> x_k+1) of the reconnection
    __extern_cpp public float jac;
    // Triangle hit (instance, triangle, uv) of the reconnection vertex or NEE light (index, random state)
    __extern_cpp public uint4 rc;
    // Direction leaving the reconnection vertex and the radiance arriving along it
    __extern_cpp public float3 dir;
    __extern_cpp public float3 radiance;
}

// Target plumbing: flex-cuda-pt's own Shift (renderer.h), as Reservoir
__target_intrinsic(cuda, "Shift")
__extern_cpp public struct Shift {
    __extern_cpp public float3 f;
    __extern_cpp public float jac;
}

__extern_cpp public struct Selection {
    __extern_cpp public Reservoir r;
    __extern_cpp public float w_sum;
    __extern_cpp public float3 color;
    __extern_cpp public uint random_state;
}

#ifdef FK_RESTIR
// Stream compaction of the temporal and paired spatial shifts (Sec. 6.2.2), sorted into bins of equal reconnection type and replay depth
public static const uint SHIFT_DEPTHS = 8u;
public static const uint SHIFT_BINS = 40u;

// Target plumbing: FlexLight's own Hit (pathtracer-compute.wgsl), the struct of flex-cuda-pt's hooks by another name
// than its own Hit, which renderer.h lays out otherwise, the struct for every other target
__target_intrinsic(wgsl, "Hit")
__target_intrinsic(cuda, "FKHit")
__extern_cpp public struct Hit {
    __extern_cpp public float2 uv;
    __extern_cpp public uint instance_index;
    __extern_cpp public uint triangle_index;
    __extern_cpp public uint is_point_light;
    __extern_cpp public float distance;
}

__extern_cpp public struct Domain {
    __extern_cpp public float3 x0;
    __extern_cpp public float3 x1;
    __extern_cpp public Hit hit;
}

// Sampling record of the previous path vertex for the reconnection criteria (Sec. 4)
__extern_cpp public struct Vertex {
    __extern_cpp public bool rough;
    __extern_cpp public uint lobe;
    __extern_cpp public float pdf;
    __extern_cpp public float cos;
    __extern_cpp public bool inside;
}
#endif

[CudaDeviceExport] public func safeDivide(a: float3, b: float3) -> float3 {
    return select(a / b, float3(0.0f), b == float3(0.0f));
}

// Weighted reservoir sampling step, weight is the vector-valued resampling weight (Sec. 6.3)
[CudaDeviceExport] public func offer(inout sel: Selection, candidate: Reservoir, weight: float3) {
    let w: float = rgb_to_greyscale(weight);
    // Also rejects NaN and infinite weights of degenerate samples
    if (!(w > 0.0f && w < 3.0e38f)) {
        return;
    }
    sel.w_sum += w;
    sel.color += weight;
    let random_value: Random = pcg(sel.random_state);
    sel.random_state = random_value.state;
    if (random_value.value * sel.w_sum <= w) {
        sel.r = candidate;
    }
}

// Resample a shifted sample with MIS weight mis, keeping its Jacobian for later shifts
[CudaDeviceExport] public func offerShifted(inout sel: Selection, r: Reservoir, shifted: Shift, mis: float) {
    var candidate: Reservoir = r;
    candidate.f = shifted.f / shifted.jac;
    candidate.jac = r.jac * shifted.jac;
    offer(sel, candidate, mis * shifted.f * r.w);
}

[CudaDeviceExport] public func finalize(sel: Selection, c: float) -> Reservoir {
    var r: Reservoir = sel.r;
    let p_hat: float = rgb_to_greyscale(r.f);
    r.w = select(0.0f, sel.w_sum / p_hat, p_hat > 0.0f);
    r.c = c;
    return r;
}

[CudaDeviceExport] public func withEnd(r: Reservoir, end_type: uint, end: uint, f: float3) -> Reservoir {
    var candidate: Reservoir = r;
    candidate.path = insertBits(insertBits(r.path, end, PATH_END, 5u), end_type, PATH_TYPE, 3u);
    candidate.f = f;
    return candidate;
}

// Decisions of ReSTIR PT both consumers make inline alike, by their expressions; each consumer keeps the loops, seeds
// and reads around them

// Single-vertex roughness threshold (Sec. 4.2)
static const float RESTIR_ROUGHNESS = 0.2;
// Dual ray footprint constant c / 100 * 4 PI of Eq. 5 with c = 0.02
static const float RESTIR_FOOTPRINT = 0.0025132741228718345;
// Temporal confidence cap and its duplication-driven reduction (Sec. 5)
static const float RESTIR_CAP = 20.0;
static const float RESTIR_CAP_MIN = 1.0;
static const float RESTIR_DUPLICATION_ALPHA = 0.1;

// Sign that turns a hit's normals toward the side the ray arrives from, which surfaces transmitting light keep
[CudaDeviceExport] public func facingSign(transmission: float, face: float3, direction: float3) -> float {
    return transmission > 0.0f || dot(face, direction) < 0.0f ? 1.0f : -1.0f;
}

// Density of a segment's end in area measure per solid angle at its start
[CudaDeviceExport] public func geometryDensity(geometry_n: float3, direction: float3, distance: float) -> float {
    return abs(dot(geometry_n, direction)) / (distance * distance);
}

// Primary ray footprint (Eq. 5) of the camera's hit
[CudaDeviceExport] public func footprintThreshold(geometry_density: float) -> float {
    return RESTIR_FOOTPRINT / geometry_density;
}

// Ray footprint criterion for reconnecting from the previous vertex to this one (Eq. 5)
[CudaDeviceExport] public func withinFootprint(open: bool, prev_rough: bool, prev_pdf: float, geometry_density: float, threshold: float) -> bool {
    return open && prev_rough && prev_pdf * geometry_density * threshold <= 1.0f;
}

// The criterion in the other direction, from this vertex along the sampled lobe
[CudaDeviceExport] public func withinInverseFootprint(pdf: float, diffuse: bool, prev_cos: float, distance: float, threshold: float) -> bool {
    return pdf > 0.0f && (diffuse || pdf * prev_cos / (distance * distance) * threshold <= 1.0f);
}

// Whether a sampled lobe is rough enough to reconnect through (Sec. 4.2)
[CudaDeviceExport] public func roughLobe(pdf: float, diffuse: bool, roughness: float) -> bool {
    return pdf > 0.0f && (diffuse || roughness >= RESTIR_ROUGHNESS);
}

// Russian roulette's probability of continuing a path of a throughput over the density of its choices. Target
// plumbing: FlexLight's clamp of the largest ratio for WGSL, flex-cuda-pt's ratio of the largest for every other
// target, equal for positive densities
[CudaDeviceExport] public func survivalProbability(throughput: float3, density: float) -> float {
    __target_switch {
    case wgsl:
    let importancy_factor: float3 = throughput / density;
    return clamp(max(importancy_factor.x, max(importancy_factor.y, importancy_factor.z)), 0.0f, 1.0f);
    default:
    return min(max(max(throughput.x, max(throughput.y, throughput.z)) / density, 0.0f), 1.0f);
    }
}

// Temporal confidence cap, lowered where the previous frame duplicated samples (Sec. 5), duplicated 0 otherwise
[CudaDeviceExport] public func confidenceCap(duplicated: float) -> float {
    return interpolate(RESTIR_CAP, RESTIR_CAP_MIN, pow(duplicated, RESTIR_DUPLICATION_ALPHA));
}
// Target plumbing: FlexLight's mix for WGSL, flex-cuda-pt's a + (b - a) * t for every other target
float interpolate(float a, float b, float t) {
    __target_switch {
    case wgsl: __intrinsic_asm "mix($0, $1, $2)";
    default: return a + (b - a) * t;
    }
}

// MIS weights of temporal reuse: of the current sample of confidence c and target p_c against the previous one shifted
// here, and of the previous one, confidence c_t, against the current one shifted back, by the targets g of the shifts
[CudaDeviceExport] public func temporalWeights(c: float, p_c: float, c_t: float, p_t: float, g_previous: float, g_current: float) -> float2 {
    return float2(c * p_c / (c * p_c + c_t * g_previous), c_t * p_t / (c_t * p_t + c * g_current));
}

// Share of a pair of spatial reuse (Sec. 3.2) in the confidence c_sum of all: the neighbor's confidence c_n and the
// current pixel's, split evenly across the pairs into c_pair
[CudaDeviceExport] public func pairShare(c_n: float, c_pair: float, c_sum: float) -> float {
    return (c_n + c_pair) / c_sum;
}

// MIS weight of the neighbor's sample of a pair, of target p_n, against the current pixel's shifted to it, g_here
[CudaDeviceExport] public func neighborWeight(share: float, c_n: float, p_n: float, c_pair: float, g_here: float) -> float {
    return share * c_n * p_n / (c_n * p_n + c_pair * g_here);
}

// The canonical sample's share against the neighbor, which the consumers count where its target p_c is positive
[CudaDeviceExport] public func canonicalWeight(share: float, c_pair: float, p_c: float, c_n: float, g_there: float) -> float {
    return share * c_pair * p_c / (c_pair * p_c + c_n * g_there);
}

// Light tree of flex-cuda-pt's renderer.cu, transpiled in its order with its names and expressions; the loops down the
// tree stay with each consumer, which reads its nodes, and take one step each of pickChild or childShare

// A node's emitters: bounds, axis and angle of their normals' cone and power (pbrt-v4's LightBounds); each consumer keeps
// its nodes' children. Target plumbing: flex-cuda-pt's own LightNode (renderer.h) holding them, the array it uploads,
// the struct for every other target
__target_intrinsic(cuda, "LightNode")
__extern_cpp public struct LightBounds {
    __extern_cpp public float3 low;
    __extern_cpp public float3 high;
    __extern_cpp public float3 w;
    __extern_cpp public float phi;
    __extern_cpp public float cos_theta_o;
};

// Of max(0, a - b) for angles a, b in [0, PI] by their sines and cosines
[CudaDeviceExport] public func cosSubClamped(sin_a: float, cos_a: float, sin_b: float, cos_b: float) -> float {
    return select(cos_a * cos_b + sin_a * sin_b, 1.0f, cos_a > cos_b);
}
[CudaDeviceExport] public func sinSubClamped(sin_a: float, cos_a: float, sin_b: float, cos_b: float) -> float {
    return select(sin_a * cos_b - cos_a * sin_b, 0.0f, cos_a > cos_b);
}
// Of an angle in [0, PI] by its cosine
[CudaDeviceExport] public func sine(c: float) -> float {
    return sqrt(max(1.0f - c * c, 0.0f));
}

// Importance of a light BVH node to a point: power times bounds of the cosines at its emitters, two sided and diffuse,
// and at the point (both hemispheres when normal is zero for transmission), over the squared distance
// (pbrt-v4's LightBounds::Importance)
[CudaDeviceExport] public func importance(node: LightBounds, p: float3, normal: float3) -> float {
    let center: float3 = (node.low + node.high) * 0.5f;
    let diagonal: float3 = node.high - node.low;
    let wi: float3 = normalize(p - center);
    let d2: float = dot(p - center, p - center);
    let r2: float = dot(diagonal, diagonal) / 4.0f;
    let cos_theta_w: float = abs(dot(node.w, wi));
    let sin_theta_o: float = sine(node.cos_theta_o);
    // Directions of the bounding sphere of the bounds, all from inside it
    let cos_theta_b: float = select(sqrt(max(1.0f - r2 / d2, 0.0f)), -1.0f, d2 < r2);
    let sin_theta_b: float = sine(cos_theta_b);
    let cos_theta_x: float = cosSubClamped(sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
    let sin_theta_x: float = sinSubClamped(sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
    let cos_theta_p: float = cosSubClamped(sin_theta_x, cos_theta_x, sin_theta_b, cos_theta_b);
    // Diffuse emitters spread a quarter turn: cos theta_e = 0
    if (cos_theta_p <= 0.0f) {
        return 0.0f;
    }
    let cos_theta_i: float = - dot(wi, normal);
    return max(node.phi * cos_theta_p / max(d2, length(diagonal) / 2.0f)
        * select(cosSubClamped(sine(cos_theta_i), cos_theta_i, sin_theta_b, cos_theta_b), 1.0f, dot(normal, normal) == 0.0f), 0.0f);
}

// Density in solid angle of a uniform point toward on a triangle of normal twice its area, the triangle picked with
// probability
[CudaDeviceExport] public func solidAngle(probability: float, normal: float3, toward: float3) -> float {
    return 2.0f * probability * pow(length(toward), 3.0f) / abs(dot(normal, toward));
}

// One step down from a node: of its children first and second, the one pick chooses by their shares of importance, 2 if
// neither has any, the pick rescaled to choose again and probability times the choice's (pbrt-v4's
// BVHLightSampler::Sample)
[CudaDeviceExport] public func pickChild(first: LightBounds, second: LightBounds, p: float3, normal: float3, inout pick: float, inout probability: float) -> uint {
    let shares: float2 = float2(importance(first, p, normal), importance(second, p, normal));
    if (shares.x == 0.0f && shares.y == 0.0f) {
        return 2u;
    }
    let total: float = shares.x + shares.y;
    let child: uint = uint(shares.y > 0.0f && pick * total >= shares.x);
    pick = min((pick * total - float(child) * shares.x) / shares[child], 0.99999994f);
    probability *= shares[child] / total;
    return child;
}

// One step down the trail of a leaf: of a node's children first and second, the share of importance of the one child
// names, as pickChild chooses it (pbrt-v4's BVHLightSampler::PMF)
[CudaDeviceExport] public func childShare(first: LightBounds, second: LightBounds, p: float3, normal: float3, child: uint) -> float {
    let shares: float2 = float2(importance(first, p, normal), importance(second, p, normal));
    return select(0.0f, shares[child] / (shares.x + shares.y), shares[child] > 0.0f);
}

// Power heuristic weight of a strategy sampling at density a against one at density b (Veach 1997)
[CudaDeviceExport] public func powerHeuristic(a: float, b: float) -> float {
    return select(1.0f, 1.0f / (1.0f + (b / a) * (b / a)), b > 0.0f);
}

// Solid angle density of sampleSphere's directions from p toward a sphere: uniform over the cone it subtends, or over
// all directions from inside it
[CudaDeviceExport] public func sphereDensity(center: float3, radius: float, p: float3) -> float {
    // Squared sine of the cone's half angle
    let sin2: float = radius * radius / dot(center - p, center - p);
    if (sin2 >= 1.0f) {
        return 0.25f / PI;
    }
    // 1 / (2 PI (1 - cos)), as 2 PI sin^2 / (1 + cos) without cancellation for small spheres
    return (1.0f + sqrt(1.0f - sin2)) / (2.0f * PI * sin2);
}

// Direction from p toward a sphere, uniform over the cone it subtends, or over all directions from inside it, by the
// uniform random numbers u1 and u2 (pbrt-v4's Sphere::Sample by solid angle)
[CudaDeviceExport] public func sampleSphere(center: float3, radius: float, p: float3, u1: float, u2: float) -> float3 {
    let sin2: float = radius * radius / dot(center - p, center - p);
    // 1 - cos theta, uniform over [0, 1 - cos of the cone's half angle], from inside over [0, 2]
    let one_minus_cos: float = select(u1 * sin2 / (1.0f + sqrt(max(1.0f - sin2, 0.0f))), 2.0f * u1, sin2 >= 1.0f);
    let sin_theta: float = sqrt(max(one_minus_cos * (2.0f - one_minus_cos), 0.0f));
    let phi: float = 2.0f * PI * u2;
    return tangentToWorld(float3(sin_theta * cos(phi), 1.0f - one_minus_cos, sin_theta * sin(phi)), normalize(center - p));
}

#ifdef FK_RESTIR
public static const float POW32 = 4294967296.0;

// Target plumbing: FlexLight's own Ray, by which its scene's hooks trace, flex-cuda-pt's FKRay, as Hit
__target_intrinsic(wgsl, "Ray")
__target_intrinsic(cuda, "FKRay")
__extern_cpp public struct Ray {
    __extern_cpp public float3 origin;
    __extern_cpp public float3 unit_direction;
}

// Ray sphere intersection test.
func raySphere(center: float3, radius: float, ray: Ray, max_len: float) -> float {
    let L: float3 = center - ray.origin;
    let tca: float = dot(L, ray.unit_direction);

    let d2: float = dot(L, L) - tca * tca;
    if (d2 > radius * radius) {
        return POW32;
    }

    let thc: float = sqrt(radius * radius - d2);
    let t0: float = tca - thc;
    let t1: float = tca + thc;

    if (t0 > BIAS && t0 < max_len) {
        return t0;
    }

    if (t1 > BIAS && t1 < max_len) {
        return t1;
    }

    return POW32;
}

__extern_cpp public struct TreeSample {
    // Unit direction toward the light point, the radiance arriving from it if visible over its density in solid angle and
    // the latter, zero for point lights of no radius
    __extern_cpp public float3 dir;
    __extern_cpp public float3 radiance;
    __extern_cpp public float density;
    __extern_cpp public uint random_state;
}

// Whether material has Blender's Translucent BSDF, a thin surface transmitting diffusely
func isTranslucent(material: Material) -> bool {
    return rgb_to_greyscale(material.translucent) > 0.0f;
}

// Light sampling at the vertex a ray left, which the emission the ray meets weighs against: whether there was none, the
// density of the lobe the ray was sampled with, the vertex, the normal its light sampling orients by, none sided, and the
// start of its shadow rays
__extern_cpp public struct NEEVertex {
    __extern_cpp public bool none;
    __extern_cpp public float pdf;
    __extern_cpp public float3 origin;
    __extern_cpp public float3 smooth_n;
    __extern_cpp public float3 start;
}

// Target plumbing: FlexLight's own Surface, which its scene's surfaceAt returns, flex-cuda-pt's FKSurface, as Hit
__target_intrinsic(wgsl, "Surface")
__target_intrinsic(cuda, "FKSurface")
__extern_cpp public struct Surface {
    __extern_cpp public float3 smooth_n;
    __extern_cpp public float3 geometry_n;
    __extern_cpp public float geometry_offset;
    __extern_cpp public Material material;
    __extern_cpp public bool skip;
    __extern_cpp public uint random_state;
}

// Surfaces transmitting nothing face the ray along dir with both normals, as in flex-cuda-pt's walk and Cycles
func facingRay(surface: Surface, dir: float3) -> Surface {
    let facing: float = facingSign(surface.material.transmission, surface.geometry_n, dir);
    return Surface(surface.smooth_n * facing, surface.geometry_n * facing, surface.geometry_offset, surface.material, surface.skip, surface.random_state);
}

__extern_cpp public struct SkySample {
    __extern_cpp public float3 dir;
    __extern_cpp public float3 radiance;
    // Radiance times the weighted BSDF of skyBSDF
    __extern_cpp public float3 color;
    __extern_cpp public uint random_state;
}

func vertexEta(material: Material, n_dot_v: float) -> float2 {
    let is_entering: bool = n_dot_v < 0.0f;
    return float2(select(1.0f, material.ior, is_entering), select(material.ior, 1.0f, is_entering));
}

// Whether the path tracer considers dir to point towards the incorrect side of the surface
func wrongSide(is_inside: bool, refracted: bool, dir: float3, geometry_n: float3) -> bool {
    return (is_inside == refracted) != (dot(dir, geometry_n) > 0.0f);
}
#endif

#ifdef FK_RESTIR
// Target plumbing: FlexLight's own Light, flex-cuda-pt's FKLight, as Hit
__target_intrinsic(wgsl, "Light")
__target_intrinsic(cuda, "FKLight")
__extern_cpp public struct Light {
    __extern_cpp public float3 position;
    __extern_cpp public float is_area_light;
    __extern_cpp public float3 color;
    __extern_cpp public float intensity;
    __extern_cpp public float variance;
}

// Target plumbing: the scene the walk, light sampling and the environment reach, each consumer's own. Where FlexLight's
// functions of the same names exist, they are the hooks; the rest read FlexLight's buffers where its layout and
// flex-cuda-pt's differ:
// lightNode(n) the leaf texel of node n of the light BVH (x zero for inner nodes, two for point lights, y the light or
// instance, z the triangle), lightSecond(n) its second child, light(i) point light i, triangleOffset(i) the first
// prototype triangle of instance i, lightTrail(j) the texel of the trail of slot j (x, y its bits) and
// slotLeaf(n, j, trail_texel) whether node n is its leaf,
// environmentCdf(cell) and environmentCdfSize() the environment map's luminance distribution, environmentMapSize() and
// ambient() its size and the color without one, maxBounces() the bounces of a path
public interface IScene {
    public Hit traverseInstanceBVH(Ray ray, bool consider_point_lights, float max_len);
    public bool shadowTraverseInstanceBVH(Ray ray, float l, bool two_sided);
    public Surface surfaceAt(Hit hit, float3 origin, uint init_random_state);
    public float3 hitPosition(Hit hit);
    public float3x3 worldTriangle(uint instance_index, uint triangle_index);
    public LightBounds lightBounds(uint n);
    public uint4 lightNode(uint n);
    public uint lightSecond(uint n);
    public uint lightSlot(Hit hit);
    public uint4 lightTrail(uint j);
    public bool slotLeaf(uint n, uint j, uint4 trail_texel);
    public Light light(uint index);
    public uint triangleOffset(uint instance_index);
    public float3 calculatePointLightContrib(uint index);
    public float3 env_map_sample(float3 dir);
    public float4 environmentCdf(uint2 cell);
    public uint2 environmentCdfSize();
    public uint2 environmentMapSize();
    public float3 ambient();
    public uint maxBounces();
}
#endif

#ifdef FK_RESTIR
// Target plumbing: the scene of the ReSTIR variant outputs, each method FlexLight's own function or the read of its
// buffer it stands for in its shader, and flex-cuda-pt's function of the name its adapter defines, in place of a call
public struct HookScene : IScene {
    __target_intrinsic(wgsl, "traverseInstanceBVH($0, $1, $2)")
    __target_intrinsic(cuda, "fcptTraverseInstanceBVH($0, $1, $2)")
    public Hit traverseInstanceBVH(Ray ray, bool consider_point_lights, float max_len);
    __target_intrinsic(wgsl, "shadowTraverseInstanceBVH($0, $1, $2)")
    __target_intrinsic(cuda, "fcptShadowTraverseInstanceBVH($0, $1, $2)")
    public bool shadowTraverseInstanceBVH(Ray ray, float l, bool two_sided);
    __target_intrinsic(wgsl, "surfaceAt($0, $1, $2)")
    __target_intrinsic(cuda, "fcptSurfaceAt($0, $1, $2)")
    public Surface surfaceAt(Hit hit, float3 origin, uint init_random_state);
    __target_intrinsic(wgsl, "hitPosition($0)")
    __target_intrinsic(cuda, "fcptHitPosition($0)")
    public float3 hitPosition(Hit hit);
    __target_intrinsic(wgsl, "worldTriangle($0, $1)")
    __target_intrinsic(cuda, "fcptWorldTriangle($0, $1)")
    public float3x3 worldTriangle(uint instance_index, uint triangle_index);
    __target_intrinsic(wgsl, "lightBounds($0)")
    __target_intrinsic(cuda, "fcptLightBounds($0)")
    public LightBounds lightBounds(uint n);
    __target_intrinsic(wgsl, "access_light_tree(4u + 4u * $0)")
    __target_intrinsic(cuda, "fcptLightNode($0)")
    public uint4 lightNode(uint n);
    __target_intrinsic(wgsl, "access_light_tree(3u + 4u * $0).w")
    __target_intrinsic(cuda, "fcptLightSecond($0)")
    public uint lightSecond(uint n);
    __target_intrinsic(wgsl, "lightSlot($0)")
    __target_intrinsic(cuda, "fcptLightSlot($0)")
    public uint lightSlot(Hit hit);
    __target_intrinsic(wgsl, "access_light_tree(access_light_tree(0u).y + $0)")
    __target_intrinsic(cuda, "fcptLightTrail($0)")
    public uint4 lightTrail(uint j);
    __target_intrinsic(wgsl, "($2.z == $0)")
    __target_intrinsic(cuda, "fcptSlotLeaf($0, $1)")
    public bool slotLeaf(uint n, uint j, uint4 trail_texel);
    __target_intrinsic(wgsl, "lights[$0]")
    __target_intrinsic(cuda, "fcptLight($0)")
    public Light light(uint index);
    __target_intrinsic(wgsl, "(instance_uint[$0 * INSTANCE_UINT_SIZE] / TRIANGLE_SIZE)")
    __target_intrinsic(cuda, "fcptTriangleOffset($0)")
    public uint triangleOffset(uint instance_index);
    __target_intrinsic(wgsl, "calculatePointLightContrib($0)")
    __target_intrinsic(cuda, "fcptCalculatePointLightContrib($0)")
    public float3 calculatePointLightContrib(uint index);
    __target_intrinsic(wgsl, "env_map_sample($0)")
    __target_intrinsic(cuda, "fcptEnvMapSample($0)")
    public float3 env_map_sample(float3 dir);
    __target_intrinsic(wgsl, "textureLoad(environment_cdf, $0, 0)")
    __target_intrinsic(cuda, "fcptEnvironmentCdf($0)")
    public float4 environmentCdf(uint2 cell);
    __target_intrinsic(wgsl, "textureDimensions(environment_cdf)")
    __target_intrinsic(cuda, "fcptEnvironmentCdfSize()")
    public uint2 environmentCdfSize();
    __target_intrinsic(wgsl, "uniforms_uint.environment_map_size")
    __target_intrinsic(cuda, "fcptEnvironmentMapSize()")
    public uint2 environmentMapSize();
    __target_intrinsic(wgsl, "uniforms_float.ambient")
    __target_intrinsic(cuda, "fcptAmbient()")
    public float3 ambient();
    __target_intrinsic(wgsl, "uniforms_uint.max_bounces")
    __target_intrinsic(cuda, "fcptMaxBounces()")
    public uint maxBounces();
}
#endif

#ifdef FK_RESTIR
// Target plumbing: WGSL's select of uints, in its argument order f, t, cond, as pathtracer.slang's of floats, which
// uints would otherwise reach through float
[ForceInline] uint select(uint f, uint t, bool cond) { return select(cond, t, f); }

// Shadow test toward a light sample, including the quick exit for lights behind the shading normal, along the shared
// segment: short of its end, which an emitting triangle's sample lifts off it toward the start
func occluded<S: IScene>(scene: S, origin: float3, smooth_n: float3, geometry_offset: float, light_dir: float3) -> bool {
    let unit_light_dir: float3 = normalize(light_dir);
    // Compute quick exit criterion to potentially skip expensive shadow test
    if (dot(smooth_n, unit_light_dir) < 0.0f) {
        return true;
    }
    // Apply geometry offset
    let offset_target: float3 = origin + geometry_offset * smooth_n;
    let light_ray: Ray = Ray(offset_target, unit_light_dir);
    return scene.shadowTraverseInstanceBVH(light_ray, shadowLength(light_dir), true);
}

// Light sampling, as flex-cuda-pt's sampleLight: a light the light BVH picks by its importance to origin, a uniform point
// on it or a direction in the cone of its sphere, seen from origin lifted by geometry_offset in front of smooth_n. Sided,
// for translucent surfaces, light all around, origin lifted to the side of the face geometry_n the light lies on
func sampleLightTree<S: IScene>(scene: S, origin: float3, smooth_n: float3, geometry_n: float3, geometry_offset: float, sided: bool, init_random_state: uint) -> TreeSample {
    let random_pick: Random = pcg(init_random_state);
    let random_side: Random = pcg(random_pick.state);
    let random_along: Random = pcg(random_side.state);
    var sample: TreeSample = TreeSample(float3(0.0f), float3(0.0f), 0.0f, random_along.state);
    let normal: float3 = select(smooth_n, float3(0.0f), sided);
    var lift_n: float3 = smooth_n;
    var start: float3 = origin + geometry_offset * lift_n;
    // From the root down to either child by its share of importance (pbrt-v4's BVHLightSampler::Sample)
    var pick: float = random_pick.value;
    var probability: float = 1.0f;
    var n: uint = 0u;
    while (scene.lightNode(n).x == 0u) {
        let second: uint = scene.lightSecond(n);
        let child: uint = pickChild(scene.lightBounds(n + 1u), scene.lightBounds(second), origin, normal, pick, probability);
        if (child > 1u) {
            return sample;
        }
        n = select(n + 1u, second, child == 1u);
    }
    if (n == 0u && !(importance(scene.lightBounds(0u), origin, normal) > 0.0f)) {
        return sample;
    }
    let leaf: uint4 = scene.lightNode(n);
    // Vector from start to the end of the shadow ray, as occluded() casts it from there
    var shadow: float3;
    if (leaf.x == 2u) {
        let light: Light = scene.light(leaf.y);
        if (sided) {
            lift_n = smooth_n * sign(dot(geometry_n, light.position - origin));
            start = origin + geometry_offset * lift_n;
        }
        if (light.variance == 0.0f) {
            // Delta light at the center
            shadow = light.position - start;
            sample.dir = normalize(light.position - start);
            sample.radiance = light.color * light.intensity / (dot(light.position - start, light.position - start) * probability);
        } else {
            sample.dir = sampleSphere(light.position, light.variance, start, random_side.value, random_along.value);
            sample.density = probability * sphereDensity(light.position, light.variance, start);
            sample.radiance = pointLightRadiance(light.color, light.intensity, light.variance) / sample.density;
            shadow = sample.dir * raySphere(light.position, light.variance, Ray(start, sample.dir), POW32);
        }
    } else {
        let triangle_index: uint = scene.triangleOffset(leaf.y) + leaf.z;
        let t: float3x3 = scene.worldTriangle(leaf.y, triangle_index);
        let side: float = sqrt(random_side.value);
        let uv: float2 = float2(side * (1.0f - random_along.value), side * random_along.value);
        let point: float3 = mul(float3(1.0f - side, uv), t);
        if (sided) {
            lift_n = smooth_n * sign(dot(geometry_n, point - origin));
            start = origin + geometry_offset * lift_n;
        } else if (!(dot(smooth_n, point - origin) > 0.0f)) {
            return sample;
        }
        // Emission at the point as the path tracer shades it, toward its smooth normal, the shadow ray ending in front of it
        let surface: Surface = scene.surfaceAt(Hit(uv, leaf.y, triangle_index, 0u, 0.0f), point, random_along.state);
        sample.random_state = surface.random_state;
        sample.dir = normalize(point - start);
        sample.density = solidAngle(probability, cross(t[1] - t[0], t[2] - t[0]), point - start);
        sample.radiance = select(surface.material.emissive * max(sign(dot(- sample.dir, surface.smooth_n)), 0.0f), float3(0.0f), surface.skip) / sample.density;
        shadow = point + shadowLift(surface.smooth_n, surface.geometry_offset, start, point) - start;
    }
    if (occluded(scene, origin, lift_n, geometry_offset, shadow)) {
        sample.radiance = float3(0.0f);
    }
    return sample;
}

// Density in solid angle of light sampling from origin, lifted to start, picking point on the light of trail slot j, down
// its trail (pbrt-v4's BVHLightSampler::PMF), as flex-cuda-pt's lightPdf; with no smooth_n, sided, all around
func lightPdf<S: IScene>(scene: S, origin: float3, smooth_n: float3, start: float3, j: uint, light_point: float3) -> float {
    let trail_texel: uint4 = scene.lightTrail(j);
    var trail: uint2 = trail_texel.xy;
    var probability: float = 1.0f;
    var n: uint = 0u;
    while (scene.lightNode(n).x == 0u) {
        let second: uint = scene.lightSecond(n);
        probability *= childShare(scene.lightBounds(n + 1u), scene.lightBounds(second), origin, smooth_n, trail.x & 1u);
        n = select(n + 1u, second, (trail.x & 1u) == 1u);
        trail = uint2((trail.x >> 1u) | (trail.y << 31u), trail.y >> 1u);
    }
    if (!scene.slotLeaf(n, j, trail_texel) || !(importance(scene.lightBounds(n), origin, smooth_n) > 0.0f) || (dot(smooth_n, smooth_n) > 0.0f && !(dot(smooth_n, light_point - origin) > 0.0f))) {
        return 0.0f;
    }
    let leaf: uint4 = scene.lightNode(n);
    if (leaf.x == 2u) {
        return probability * sphereDensity(scene.light(leaf.y).position, scene.light(leaf.y).variance, start);
    }
    let t: float3x3 = scene.worldTriangle(leaf.y, scene.triangleOffset(leaf.y) + leaf.z);
    return solidAngle(probability, cross(t[1] - t[0], t[2] - t[0]), light_point - start);
}

// BSDF times the radiance of a light sample, weighted per lobe against sampling the BSDF where a direction it samples
// competes, by the power heuristic, delta lights never competing
func lightBSDF(in_dir: float3, light: TreeSample, smooth_n: float3, geometry_n: float3, material: Material, eta_i: float, eta_o: float, competing: bool, random_state: uint) -> float3 {
    if (!competing || light.density == 0.0f) {
        // Translucent materials transmit past the face too, counting none of the share sampling mirrors back across it
        if (isTranslucent(material)) {
            return translucentBSDF(in_dir, light.dir, smooth_n, geometry_n, material, eta_i, eta_o, random_state) * light.radiance;
        }
        return BSDF(in_dir, light.dir, smooth_n, geometry_n, material, eta_i, eta_o, random_state) * light.radiance;
    }
    let refracted: bool = dot(geometry_n, - in_dir) * dot(geometry_n, light.dir) <= 0.0f;
    return neeBSDF(in_dir, light.dir, smooth_n, material, eta_i, eta_o, refracted, light.density, true, random_state) * light.radiance * light.density;
}

// Weight of emission met at point on the light of hit against light sampling at the vertex the ray left
func emissionWeight<S: IScene>(scene: S, vertex: NEEVertex, hit: Hit, light_point: float3) -> float {
    if (vertex.none) {
        return 1.0f;
    }
    return powerHeuristic(vertex.pdf, lightPdf(scene, vertex.origin, vertex.smooth_n, vertex.start, scene.lightSlot(hit), light_point));
}
#endif

#ifdef FK_RESTIR
func environmentMapped<S: IScene>(scene: S) -> bool {
    return scene.environmentMapSize().x > 1u && scene.environmentMapSize().y > 1u;
}

// Solid angle density of sampleSky, piecewise constant over the luminance distribution of the environment map
func environmentPdf<S: IScene>(scene: S, dir: float3) -> float {
    let size: uint2 = scene.environmentCdfSize() - uint2(1u, 0u);
    // Same coordinates as env_map_sample
    let st: float2 = float2(atan2(- dir.z, - dir.x) / (2.0f * PI) + 0.5f, acos(clamp(dir.y, -1.0f, 1.0f)) / PI);
    let cell: uint2 = min(uint2(st * float2(size)), size - 1u);
    let p: float = scene.environmentCdf(cell).y * scene.environmentCdf(uint2(size.x, cell.y)).y;
    return p * float(size.x * size.y) / (2.0f * PI * PI * length(dir.xz));
}

// First entry of a row or of the marginal column of the environment CDF exceeding u
func searchCDF<S: IScene>(scene: S, start: uint2, step: uint2, count: uint, u: float) -> uint {
    var low: uint = 0u;
    var high: uint = count - 1u;
    while (low < high) {
        let middle: uint = (low + high) / 2u;
        if (scene.environmentCdf(start + step * middle).x > u) {
            high = middle;
        } else {
            low = middle + 1u;
        }
    }
    return low;
}

// Radiance the path tracer's ray from a vertex along dir receives from the environment map if it hits nothing on the way.
// Escapes passing transparent texels are left to BSDF sampling.
func skyRadiance<S: IScene>(scene: S, origin: float3, surface: Surface, is_inside: bool, dir: float3) -> float3 {
    let inside: bool = is_inside != wrongSide(is_inside, false, dir, surface.geometry_n);
    let ray: Ray = Ray(origin + surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, inside), dir);
    return select(scene.env_map_sample(dir), float3(0.0f), scene.shadowTraverseInstanceBVH(ray, POW32, true));
}

// Next event estimation toward the environment map, drawing a direction by its luminance. lobe_state is the random state of skyBSDF.
func sampleSky<S: IScene>(scene: S, ray: Ray, surface: Surface, eta: float2, is_inside: bool, init_random_state: uint, lobe_state: uint) -> SkySample {
    let size: uint2 = scene.environmentCdfSize() - uint2(1u, 0u);
    let random_0: Random = pcg(init_random_state);
    let random_1: Random = pcg(random_0.state);
    let random_2: Random = pcg(random_1.state);
    let random_3: Random = pcg(random_2.state);
    let row: uint = searchCDF(scene, uint2(size.x, 0u), uint2(0u, 1u), size.y, random_0.value);
    let column: uint = searchCDF(scene, uint2(0u, row), uint2(1u, 0u), size.x, random_1.value);
    let angles: float2 = (float2(float(column), float(row)) + float2(random_2.value, random_3.value)) / float2(size) * float2(2.0f * PI, PI);
    let dir: float3 = float3(sin(angles.y) * cos(angles.x), cos(angles.y), sin(angles.y) * sin(angles.x));
    let pdf: float = environmentPdf(scene, dir);
    let f: float3 = skyBSDF(ray.unit_direction, dir, surface, eta, is_inside, pdf, lobe_state);
    // Only trace toward directions that contribute
    if (!(pdf > 0.0f) || all(f == float3(0.0f))) {
        return SkySample(dir, float3(0.0f), float3(0.0f), random_3.state);
    }
    let radiance: float3 = skyRadiance(scene, ray.origin, surface, is_inside, dir);
    return SkySample(dir, radiance, f * radiance, random_3.state);
}

// BSDF times cosine toward an environment sample over its density, each lobe weighted against the BSDF sampled escape by the
// balance heuristic. Lobes sampling can't produce toward dir are left to rays sampled to the wrong side, sampled again or mirrored.
func skyBSDF(in_dir: float3, dir: float3, surface: Surface, eta: float2, is_inside: bool, pdf: float, random_state: uint) -> float3 {
    let refracted: bool = wrongSide(is_inside, false, dir, surface.geometry_n);
    return neeBSDF(in_dir, dir, surface.smooth_n, surface.material, eta.x, eta.y, refracted, pdf, false, random_state);
}

// MIS weight of a BSDF sampled escape from a vertex doing next event estimation, pdf is the density of the sampled lobe.
// Delta lobes and rays sampled to the wrong side of the face (pdf zero) are never drawn by sampleSky.
func escapeWeight<S: IScene>(scene: S, pdf: float, dir: float3) -> float {
    if (pdf <= 0.0f || !environmentMapped(scene)) {
        return 1.0f;
    }
    return pdf / (pdf + environmentPdf(scene, dir));
}

func environment<S: IScene>(scene: S, dir: float3) -> float3 {
    if (scene.environmentMapSize().x > 1u && scene.environmentMapSize().y > 1u) {
        return scene.env_map_sample(dir);
    }
    // If no environment map is present, use ambient color
    return scene.ambient();
}
#endif

#ifdef FK_RESTIR
// Target plumbing: WGSL's extractBits of a uint, as pathtracer.slang's insertBits
uint extractBits(uint e, uint offset, uint count) {
    __target_switch {
    case wgsl: __intrinsic_asm "extractBits($0, $1, $2)";
    default: return (e >> offset) & ((1u << count) - 1u);
    }
}

// Walk a path from dom like lightTrace. Generating, every path of the tree is resampled into sel with its reconnection
// vertex (Sec. 6.1), Russian roulette only modifies their source density (Sec. 6.2.4). Replaying, the hybrid shift maps r into
// dom (Sec. 2.3): random replay up to x_k-1 and reconnection to x_k. It returns the shifted integrand times the Jacobian
// determinant of Eq. 2, zero if the path is not in the image of the shift.
func walk<S: IScene>(scene: S, dom: Domain, r: Reservoir, replay: bool, scale: float, inout sel: Selection) -> Shift {
    let fail: Shift = Shift(float3(0.0f), 0.0f);
    let end: uint = extractBits(r.path, PATH_END, 5u);
    let k: uint = extractBits(r.path, PATH_K, 5u);
    let rc: uint = extractBits(r.path, PATH_RC, 2u);
    let end_type: uint = extractBits(r.path, PATH_TYPE, 3u);
    // The environment is only reached after a further bounce
    if (replay && end + select(0u, 1u, end_type >= END_ENV) > scene.maxBounces()) {
        return fail;
    }
    // Replaying stops sampling at x_k-1 for reconnections and at the path end otherwise
    let stop: uint = select(k - 1u, end + select(0u, 1u, end_type == END_ENV), rc == RC_NONE);
    let rc_hit: Hit = Hit(asfloat(r.rc.zw), r.rc.x, r.rc.y, 0u, 0.0f);
    var ray: Ray = Ray(dom.x1, normalize(dom.x1 - dom.x0));
    var hit: Hit = dom.hit;
    var throughput: float3 = float3(1.0f);
    // Replaying the densities of the reconnection, generating the product of Russian roulette survival probabilities
    var density: float = 1.0f;
    var is_inside: bool = false;
    // Light sampling at the vertex the ray left, none at the camera
    var nee_vertex: NEEVertex = NEEVertex(true, 0.0f, float3(0.0f), float3(0.0f), float3(0.0f));
    var threshold: float = 0.0f;
    var reconnection: float3 = {};
    var prev: Vertex = {};
    // Template for generated paths reconnecting at the first vertex meeting both footprint criteria
    var chain: Reservoir = {};
    chain.seed = r.seed;
    var chain_throughput: float3 = float3(0.0f);
    for (var b: uint = 0u; ; b++) {
        let point_light_lighting: bool = hit.is_point_light == 1u;
        // Loop scoped variables are initialized explicitly, some compilers keep the previous iteration's value otherwise
        var surface: Surface = {};
        // Smooth normal the surface emits along, before it faces the ray
        var front_n: float3 = float3(0.0f);
        var scatter: bool = false;
        var geometry_density: float = 0.0f;
        if (!point_light_lighting) {
            surface = scene.surfaceAt(hit, ray.origin, stream(r.seed, b));
            front_n = surface.smooth_n;
            surface = facingRay(surface, ray.unit_direction);
            if (is_inside) {
                throughput *= beerLambert(hit.distance, surface.material.absorption);
            }
            scatter = !surface.skip;
            geometry_density = geometryDensity(surface.geometry_n, ray.unit_direction, hit.distance);
            if (b == 0u) {
                // Primary ray footprint (Eq. 5)
                threshold = footprintThreshold(geometry_density);
            }
        }
        // Ray footprint criterion for reconnecting from the previous vertex to this one (Eq. 5)
        let footprint: bool = withinFootprint(scatter, prev.rough, prev.pdf, geometry_density, threshold);
        let material: Material = surface.material;
        let n_dot_v: float = dot(surface.smooth_n, - ray.unit_direction);
        let eta: float2 = vertexEta(material, n_dot_v);
        let nee: bool = scatter && samplesLights(material);
        // Emission met, of the surface or a point light, weighted against light sampling at the vertex the ray left
        var emission: float3 = material.emissive * max(sign(dot(- ray.unit_direction, front_n)), 0.0f);
        if (point_light_lighting) {
            emission = scene.calculatePointLightContrib(hit.instance_index);
        }
        if (rgb_to_greyscale(emission) > 0.0f) {
            emission *= emissionWeight(scene, nee_vertex, hit, ray.origin);
        }
        // Replaying the suffix after the reconnection vertex up to the emission it ends at
        if (replay && rc == RC_SURFACE && b > k && b == end && (end_type == END_EMIT || end_type == END_POINT)) {
            if (point_light_lighting != (end_type == END_POINT)) {
                return fail;
            }
            return Shift(throughput * emission / r.jac, density / r.jac);
        }
        let chain_found: bool = extractBits(chain.path, PATH_RC, 2u) == RC_SURFACE;
        // Reconnection at this vertex for paths ending here
        var here: Reservoir = chain;
        here.path = insertBits(insertBits(insertBits(insertBits(0u, b, PATH_K, 5u), RC_SURFACE, PATH_RC, 2u), prev.lobe, PATH_LOBE_PREV, 2u), select(0u, 1u, prev.inside), PATH_INSIDE, 1u);
        here.jac = prev.pdf * geometry_density;
        here.rc = uint4(hit.instance_index, hit.triangle_index, asuint(hit.uv));
        let arrived: bool = replay && rc == RC_SURFACE && b == k;
        if (arrived) {
            // The stored path takes over at the reconnection vertex
            if (hit.instance_index != rc_hit.instance_index || hit.triangle_index != rc_hit.triangle_index || !footprint) {
                return fail;
            }
            throughput *= geometry_density;
            density *= geometry_density;
            if (k == end && end_type == END_EMIT) {
                return Shift(throughput * emission / r.jac, density / r.jac);
            }
            // Light sampling at the reconnection vertex replays its random numbers, as the light may have moved
            if (k == end && end_type == END_NEE) {
                let light: TreeSample = sampleLightTree(scene, ray.origin, surface.smooth_n, surface.geometry_n, surface.geometry_offset, isTranslucent(material), stream(r.seed, b + STREAM_NEE));
                if (!nee || !(rgb_to_greyscale(light.radiance) > 0.0f)) {
                    return fail;
                }
                return Shift(throughput * lightBSDF(ray.unit_direction, light, surface.smooth_n, surface.geometry_n, material, eta.x, eta.y, b < scene.maxBounces(), surface.random_state) / r.jac, density / r.jac);
            }
            if (k == end && end_type == END_SKY) {
                if (!nee) {
                    return fail;
                }
                return Shift(throughput * skyBSDF(ray.unit_direction, r.dir, surface, eta, is_inside, environmentPdf(scene, r.dir), surface.random_state) * r.radiance / r.jac, density / r.jac);
            }
            if (nee != (extractBits(r.path, PATH_NEE, 1u) == 1u)) {
                return fail;
            }
        } else if (replay && b == stop && (!scatter || (rc != RC_SURFACE && rc != RC_ENV))) {
            if (rc == RC_LIGHT && nee && !footprint && end_type == END_SKY) {
                // Forced reconnection to the environment direction, drawn independently of the vertex (unit Jacobian)
                let sky: SkySample = sampleSky(scene, ray, surface, eta, is_inside, stream(r.seed, b + STREAM_SKY), surface.random_state);
                return Shift(throughput * sky.color, 1.0f);
            }
            if (rc == RC_LIGHT && nee && !footprint) {
                // Forced reconnection to the light vertex of next event estimation (Sec. 6.2.3), the point its replayed
                // random numbers pick again (unit Jacobian)
                let light: TreeSample = sampleLightTree(scene, ray.origin, surface.smooth_n, surface.geometry_n, surface.geometry_offset, isTranslucent(material), stream(r.seed, b + STREAM_NEE));
                if (!(rgb_to_greyscale(light.radiance) > 0.0f)) {
                    return fail;
                }
                return Shift(throughput * lightBSDF(ray.unit_direction, light, surface.smooth_n, surface.geometry_n, material, eta.x, eta.y, b < scene.maxBounces(), surface.random_state), 1.0f);
            }
            if (rc == RC_NONE && end_type == END_POINT && point_light_lighting) {
                return Shift(throughput * emission, 1.0f);
            }
            // Emission seen right after a vertex, against its next event estimation
            if (rc == RC_NONE && end_type == END_EMIT && scatter && !footprint) {
                return Shift(throughput * emission, 1.0f);
            }
            return fail;
        } else if (!replay && scatter) {
            // Emission seen directly carries no randomness to resample, shading adds it
            if (b > 0u) {
                var candidate: Reservoir = chain;
                if (chain_found) {
                    candidate.radiance = safeDivide(throughput * emission, chain_throughput);
                } else if (footprint) {
                    candidate = here;
                }
                offer(sel, withEnd(candidate, END_EMIT, b, throughput * emission), throughput * emission * scale / density);
            }
            if (nee) {
                let light: TreeSample = sampleLightTree(scene, ray.origin, surface.smooth_n, surface.geometry_n, surface.geometry_offset, isTranslucent(material), stream(r.seed, b + STREAM_NEE));
                let f: float3 = throughput * lightBSDF(ray.unit_direction, light, surface.smooth_n, surface.geometry_n, material, eta.x, eta.y, b < scene.maxBounces(), surface.random_state);
                var candidate: Reservoir = chain;
                if (chain_found) {
                    candidate.radiance = safeDivide(f, chain_throughput);
                } else if (footprint) {
                    candidate = here;
                    candidate.path = insertBits(candidate.path, 1u, PATH_NEE, 1u);
                    candidate.dir = light.dir;
                    candidate.radiance = light.radiance;
                } else {
                    // Forced reconnection to the light vertex (Sec. 6.2.3)
                    candidate.path = insertBits(insertBits(0u, b + 1u, PATH_K, 5u), RC_LIGHT, PATH_RC, 2u);
                }
                offer(sel, withEnd(candidate, END_NEE, b, f), f * scale / density);
            }
            if (nee && environmentMapped(scene) && b < scene.maxBounces()) {
                let sky: SkySample = sampleSky(scene, ray, surface, eta, is_inside, stream(r.seed, b + STREAM_SKY), surface.random_state);
                let f: float3 = throughput * sky.color;
                var candidate: Reservoir = chain;
                if (chain_found) {
                    candidate.radiance = safeDivide(f, chain_throughput);
                } else if (footprint) {
                    candidate = here;
                    candidate.path = insertBits(candidate.path, 1u, PATH_NEE, 1u);
                    candidate.dir = sky.dir;
                    candidate.radiance = sky.radiance;
                } else {
                    // Forced reconnection to the environment direction
                    candidate.path = insertBits(insertBits(0u, b + 1u, PATH_K, 5u), RC_LIGHT, PATH_RC, 2u);
                }
                offer(sel, withEnd(candidate, END_SKY, b, f), f * scale / density);
            }
        }
        if (scatter) {
            // Replaying, x_k-1 connects to the reconnection vertex and x_k leaves along the stored direction with the stored lobes
            let connect: bool = replay && b == stop;
            var lobe_index: uint = select(extractBits(r.path, PATH_LOBE_PREV, 2u), extractBits(r.path, PATH_LOBE, 2u), arrived);
            var dir: float3 = r.dir;
            var refracted: bool = lobe_index == LOBE_REFRACT;
            var wrong_side: bool = false;
            // Sample leaving this vertex, without density when sampled to the wrong side of the face
            var lobe: SampleBSDF = {};
            if (connect) {
                if (is_inside != (extractBits(r.path, PATH_INSIDE, 1u) == 1u)) {
                    return fail;
                }
                if (rc == RC_SURFACE) {
                    reconnection = scene.hitPosition(rc_hit);
                }
                // A translucent material's diffuse lobe connects through to the other side of its smooth normal too
                refracted = refracted || (isTranslucent(material) && lobe_index == LOBE_DIFFUSE && dot(surface.smooth_n, select(r.dir, reconnection - ray.origin, rc == RC_SURFACE)) * n_dot_v < 0.0f);
                if (rc == RC_SURFACE) {
                    dir = normalize(reconnection - (ray.origin + surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, is_inside != refracted)));
                }
                // The path tracer samples again or mirrors directions sampled to the wrong side of the face, which no density reaches
                if (wrongSide(is_inside, refracted, dir, surface.geometry_n)) {
                    return fail;
                }
            } else if (!arrived) {
                var bsdf_sampled: SampleBSDF = sampleBSDF(ray.unit_direction, surface.smooth_n, material, eta.x, eta.y, surface.random_state, float2(0.0f));
                // Rays sampled to the wrong side of the face are sampled again or mirrored, as the path tracer's
                wrong_side = wrongSide(is_inside, bsdf_sampled.refracted, bsdf_sampled.unit_direction, surface.geometry_n);
                if (wrong_side && material.transmission > 0.0f) {
                    let geometry_bsdf_sampled: SampleBSDF = sampleBSDF(bsdf_sampled.unit_direction, surface.geometry_n, material, eta.x, eta.y, bsdf_sampled.random_state, float2(0.0f));
                    bsdf_sampled.unit_direction = geometry_bsdf_sampled.unit_direction;
                    bsdf_sampled.refracted = geometry_bsdf_sampled.refracted;
                    bsdf_sampled.throughput = geometry_bsdf_sampled.throughput;
                } else if (wrong_side) {
                    bsdf_sampled.unit_direction -= 2.0f * dot(bsdf_sampled.unit_direction, surface.geometry_n) * surface.geometry_n;
                }
                lobe_index = bsdf_sampled.lobe;
                dir = bsdf_sampled.unit_direction;
                refracted = bsdf_sampled.refracted;
                lobe = bsdf_sampled;
                lobe.pdf = select(bsdf_sampled.pdf, 0.0f, wrong_side);
            }
            // Connections evaluate the given direction
            if (connect || arrived) {
                lobe = connectBSDF(ray.unit_direction, dir, surface.smooth_n, material, eta.x, eta.y, lobe_index, surface.random_state);
            }
            // Delta lobes have no competing light sample, straight transmission keeps the preceding vertex's weights
            let delta: bool = lobe_index != LOBE_DIFFUSE && (material.roughness == 0.0f || (lobe_index == LOBE_REFRACT && eta.x == eta.y));
            // Translucent surfaces are thin, as in the path tracer
            let through: bool = isTranslucent(material) && lobe_index == LOBE_DIFFUSE && dot(dir, surface.geometry_n) < 0.0f;
            if (nee && !delta && !wrong_side) {
                nee_vertex = NEEVertex(false, lobe.pdf, ray.origin, select(surface.smooth_n, float3(0.0f), isTranslucent(material)), ray.origin + surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, through));
            } else if (lobe_index != LOBE_REFRACT || eta.x != eta.y) {
                nee_vertex.none = true;
            }
            // Inverse ray footprint criterion for the density of the direction leaving this vertex (Eq. 5)
            let inverse_footprint: bool = withinInverseFootprint(lobe.pdf, lobe_index == LOBE_DIFFUSE, prev.cos, hit.distance, threshold);
            let rough: bool = roughLobe(lobe.pdf, lobe_index == LOBE_DIFFUSE, material.roughness);
            if (arrived) {
                if (!inverse_footprint) {
                    return fail;
                }
                if (end_type != END_EMIT && end_type != END_POINT) {
                    // An escape right after x_k is weighted against next event estimation with its new incoming direction
                    let weight: float = select(1.0f, escapeWeight(scene, select(0.0f, lobe.pdf, nee), r.dir), k == end && end_type == END_ENV);
                    return Shift(throughput * (lobe.throughput * lobe.pdf) * r.radiance * weight / r.jac, density * lobe.pdf / r.jac);
                }
                // The weight of emission depends on the reconnected BSDF, the suffix replays instead of its radiance
                throughput *= lobe.pdf;
                density *= lobe.pdf;
            }
            // A replayed path meeting the criteria before x_k is not in the image of the shift
            if ((replay && b <= stop && footprint && inverse_footprint) || (connect && !rough)) {
                return fail;
            }
            if (connect) {
                throughput *= lobe.throughput * lobe.pdf;
                density = lobe.pdf;
            } else {
                throughput *= max(lobe.throughput, float3(0.0f));
            }
            if (!replay && !chain_found && footprint && inverse_footprint) {
                chain = here;
                chain.path = insertBits(insertBits(chain.path, lobe_index, PATH_LOBE, 2u), select(0u, 1u, nee), PATH_NEE, 1u);
                chain.jac *= lobe.pdf;
                chain.dir = dir;
                chain_throughput = throughput;
            }
            prev = Vertex(rough, lobe_index, lobe.pdf, abs(dot(surface.geometry_n, dir)), is_inside);
            if (refracted && !through) {
                is_inside = !is_inside;
            }
            ray.unit_direction = dir;
            ray.origin += surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, is_inside != through);
        } else {
            prev.rough = false;
            // Environment next event estimation never passes texels, escapes through them take the full weight
            prev.pdf = 0.0f;
        }
        if (!replay) {
            if (point_light_lighting) {
                let f: float3 = throughput * emission;
                var candidate: Reservoir = chain;
                if (extractBits(chain.path, PATH_RC, 2u) == RC_SURFACE) {
                    candidate.radiance = safeDivide(f, chain_throughput);
                }
                offer(sel, withEnd(candidate, END_POINT, b, f), f * scale / density);
            }
            var survival_probability: float = 1.0f;
            if (point_light_lighting || scatter) {
                survival_probability = survivalProbability(throughput, density);
            }
            if (survival_probability < pcg(stream(r.seed, b + STREAM_RR)).value || b >= scene.maxBounces()) {
                break;
            }
            density *= survival_probability;
        }
        // Only occluders in front of the reconnection vertex matter, passing through a point light no other
        hit = scene.traverseInstanceBVH(ray, !point_light_lighting, select(POW32, distance(reconnection, ray.origin) * 1.001f, replay && b == stop && rc == RC_SURFACE));
        // Reaching the reconnection vertex, it is shaded exactly where the stored path has it
        if (replay && b == stop && rc == RC_SURFACE && hit.instance_index == rc_hit.instance_index && hit.triangle_index == rc_hit.triangle_index) {
            hit.uv = rc_hit.uv;
            hit.distance = distance(reconnection, ray.origin);
        }
        // The connection to the environment direction has to escape the scene
        if (replay && b == stop && rc == RC_ENV && hit.instance_index != UINT_MAX) {
            return fail;
        }
        if (hit.instance_index == UINT_MAX) {
            // BSDF sampled escapes share the environment with its next event estimation
            let weight: float = escapeWeight(scene, select(0.0f, prev.pdf, !nee_vertex.none), ray.unit_direction);
            let f: float3 = throughput * environment(scene, ray.unit_direction);
            if (replay) {
                if (b == stop && rc == RC_ENV) {
                    return Shift(f * weight / r.jac, density / r.jac);
                }
                if (rc == RC_NONE && end_type == END_ENV && b == end && !prev.rough) {
                    return Shift(f * weight, 1.0f);
                }
                return fail;
            }
            var candidate: Reservoir = chain;
            if (extractBits(chain.path, PATH_RC, 2u) == RC_SURFACE) {
                // Escaping right after x_k, the shift evaluates the weight with the new incoming direction
                candidate.radiance = safeDivide(f * select(weight, 1.0f, extractBits(chain.path, PATH_K, 5u) == b), chain_throughput);
            } else if (prev.rough) {
                // Reconnection to the environment direction, guarded by the roughness threshold only (Sec. 4.2)
                candidate.path = insertBits(insertBits(insertBits(insertBits(0u, b + 1u, PATH_K, 5u), RC_ENV, PATH_RC, 2u), prev.lobe, PATH_LOBE_PREV, 2u), select(0u, 1u, prev.inside), PATH_INSIDE, 1u);
                candidate.jac = prev.pdf;
                candidate.dir = ray.unit_direction;
            }
            offer(sel, withEnd(candidate, END_ENV, b, f * weight), f * weight * scale / density);
            break;
        }
        // Project ray origin to hit point
        ray.origin += hit.distance * ray.unit_direction;
    }
    return fail;
}
#endif
