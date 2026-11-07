implementing pathtracer;

#if FK_RESTIR
// ReSTIR PT Enhanced (Lin, Kettunen and Wyman 2026)

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
#if FK_RESTIR
public static const uint PATH_K = 5u;
public static const uint PATH_RC = 10u;
#endif
public static const uint PATH_TYPE = 12u;
#if FK_RESTIR
public static const uint PATH_LOBE_PREV = 15u;
public static const uint PATH_LOBE = 18u;
public static const uint PATH_NEE = 21u;
public static const uint PATH_INSIDE = 22u;

// Random streams besides the per vertex ones
public static const uint STREAM_NEE = 64u;
public static const uint STREAM_RR = 128u;
public static const uint STREAM_SELECT = 193u;
public static const uint STREAM_SKY = 256u;
#endif

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

#if FK_RESTIR
// Stream compaction of the temporal and paired spatial shifts (Sec. 6.2.2), sorted into bins of equal reconnection type and replay depth
public static const uint SHIFT_DEPTHS = 8u;
public static const uint SHIFT_BINS = 40u;

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

// Weighted reservoir sampling (Sec. 6.3): w_sum += w, candidate kept with probability w / w_sum
[CudaDeviceExport] public func offer(inout sel: Selection, candidate: Reservoir, weight: float3) {
    let w: float = rgb_to_greyscale(weight);
    // Reject 0, NaN and infinite weights
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

// shifted.f = f(y) * |J|
// => resampling weight = mis * f(y) * |J| * W, candidate f = f(y), jac *= |J|
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


// Single-vertex roughness threshold (Sec. 4.2)
static const float RESTIR_ROUGHNESS = 0.2;
// Dual ray footprint constant c / 100 * 4 PI of Eq. 5 with c = 0.02
static const float RESTIR_FOOTPRINT = 0.0025132741228718345;
// Temporal confidence cap and its duplication-driven reduction (Sec. 5)
static const float RESTIR_CAP = 20.0;
static const float RESTIR_CAP_MIN = 1.0;
static const float RESTIR_DUPLICATION_ALPHA = 0.1;

// Sign turning the normals toward the arriving ray, kept for transmitting surfaces
[CudaDeviceExport] public func facingSign(transmission: float, face: float3, direction: float3) -> float {
    return transmission > 0.0f || dot(face, direction) < 0.0f ? 1.0f : -1.0f;
}

// PDF_area = PDF_solid_angle * |cos_theta| / distance^2
// => PDF_area / PDF_solid_angle = |dot(geometry_n, direction)| / distance^2
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

// Eq. 5 from this vertex along the sampled lobe
[CudaDeviceExport] public func withinInverseFootprint(pdf: float, diffuse: bool, prev_cos: float, distance: float, threshold: float) -> bool {
    return pdf > 0.0f && (diffuse || pdf * prev_cos / (distance * distance) * threshold <= 1.0f);
}

// Whether a sampled lobe is rough enough to reconnect through (Sec. 4.2)
[CudaDeviceExport] public func roughLobe(pdf: float, diffuse: bool, roughness: float) -> bool {
    return pdf > 0.0f && (diffuse || roughness >= RESTIR_ROUGHNESS);
}

// Russian roulette: q = min(max(throughput) / density, 1)
[CudaDeviceExport] public func survivalProbability(throughput: float3, density: float) -> float {
    __target_switch {
    case wgsl:
    let importancy_factor: float3 = throughput / density;
    return clamp(max(importancy_factor.x, max(importancy_factor.y, importancy_factor.z)), 0.0f, 1.0f);
    default:
    return min(max(max(throughput.x, max(throughput.y, throughput.z)) / density, 0.0f), 1.0f);
    }
}

// Temporal confidence cap (Sec. 5)
[CudaDeviceExport] public func confidenceCap(duplicated: float) -> float {
    return interpolate(RESTIR_CAP, RESTIR_CAP_MIN, pow(duplicated, RESTIR_DUPLICATION_ALPHA));
}
float interpolate(float a, float b, float t) {
    __target_switch {
    case wgsl: __intrinsic_asm "mix($0, $1, $2)";
    default: return a + (b - a) * t;
    }
}

// Temporal MIS weights, p_t->c = g_previous the previous sample shifted here, p_c->t = g_current
// m_c = c * p_c / (c * p_c + c_t * p_t->c)
// m_t = c_t * p_t / (c_t * p_t + c * p_c->t)
[CudaDeviceExport] public func temporalWeights(c: float, p_c: float, c_t: float, p_t: float, g_previous: float, g_current: float) -> float2 {
    return float2(c * p_c / (c * p_c + c_t * g_previous), c_t * p_t / (c_t * p_t + c * g_current));
}

// Pair's share of all confidence (Sec. 3.2)
[CudaDeviceExport] public func pairShare(c_n: float, c_pair: float, c_sum: float) -> float {
    return (c_n + c_pair) / c_sum;
}

// Pairwise MIS weight of the neighbor's sample, g_here its target shifted to the current pixel
[CudaDeviceExport] public func neighborWeight(share: float, c_n: float, p_n: float, c_pair: float, g_here: float) -> float {
    return share * c_n * p_n / (c_n * p_n + c_pair * g_here);
}

// Pairwise MIS weight of the canonical sample, g_there its target shifted to the neighbor
[CudaDeviceExport] public func canonicalWeight(share: float, c_pair: float, p_c: float, c_n: float, g_there: float) -> float {
    return share * c_pair * p_c / (c_pair * p_c + c_n * g_there);
}


// Bounds, normal cone (w, cos_theta_o) and power phi of a node's emitters (pbrt-v4 LightBounds)
__target_intrinsic(cuda, "LightNode")
__extern_cpp public struct LightBounds {
    __extern_cpp public float3 low;
    __extern_cpp public float3 high;
    __extern_cpp public float3 w;
    __extern_cpp public float phi;
    __extern_cpp public float cos_theta_o;
};

// cos(max(0, a - b)) = cos_a * cos_b + sin_a * sin_b, 1 for a < b
[CudaDeviceExport] public func cosSubClamped(sin_a: float, cos_a: float, sin_b: float, cos_b: float) -> float {
    return select(cos_a * cos_b + sin_a * sin_b, 1.0f, cos_a > cos_b);
}
[CudaDeviceExport] public func sinSubClamped(sin_a: float, cos_a: float, sin_b: float, cos_b: float) -> float {
    return select(sin_a * cos_b - cos_a * sin_b, 0.0f, cos_a > cos_b);
}
// sin = sqrt(1 - cos^2) on [0, PI]
[CudaDeviceExport] public func sine(c: float) -> float {
    return sqrt(max(1.0f - c * c, 0.0f));
}

// Importance of a node to p (pbrt-v4 LightBounds::Importance)
// theta_x = max(0, theta_w - theta_o), theta_p = max(0, theta_x - theta_b)
// importance = phi * cos(theta_p) / max(d^2, |diagonal| / 2) * cos(max(0, theta_i - theta_b)), 1 without normal
[CudaDeviceExport] public func importance(node: LightBounds, p: float3, normal: float3) -> float {
    let center: float3 = (node.low + node.high) * 0.5f;
    let diagonal: float3 = node.high - node.low;
    let wi: float3 = normalize(p - center);
    let d2: float = dot(p - center, p - center);
    let r2: float = dot(diagonal, diagonal) / 4.0f;
    let cos_theta_w: float = abs(dot(node.w, wi));
    let sin_theta_o: float = sine(node.cos_theta_o);
    // sin(theta_b) = r / d of the bounding sphere, all directions from inside it
    let cos_theta_b: float = select(sqrt(max(1.0f - r2 / d2, 0.0f)), -1.0f, d2 < r2);
    let sin_theta_b: float = sine(cos_theta_b);
    let cos_theta_x: float = cosSubClamped(sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
    let sin_theta_x: float = sinSubClamped(sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
    let cos_theta_p: float = cosSubClamped(sin_theta_x, cos_theta_x, sin_theta_b, cos_theta_b);
    // theta_p >= theta_e = PI / 2 => no light
    if (cos_theta_p <= 0.0f) {
        return 0.0f;
    }
    let cos_theta_i: float = - dot(wi, normal);
    return max(node.phi * cos_theta_p / max(d2, length(diagonal) / 2.0f)
        * select(cosSubClamped(sine(cos_theta_i), cos_theta_i, sin_theta_b, cos_theta_b), 1.0f, dot(normal, normal) == 0.0f), 0.0f);
}

// Uniform point on the triangle: PDF_area = probability / area, area = |normal| / 2
// PDF = PDF_area * |toward|^2 / |cos| , |cos| = |dot(normal, toward)| / (|normal| * |toward|)
// => PDF = 2 * probability * |toward|^3 / |dot(normal, toward)|
[CudaDeviceExport] public func solidAngle(probability: float, normal: float3, toward: float3) -> float {
    return 2.0f * probability * pow(length(toward), 3.0f) / abs(dot(normal, toward));
}

// One step down the light tree by the children's importance, pick rescaled (pbrt-v4 BVHLightSampler::Sample)
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

// Probability of one step down to child (pbrt-v4 BVHLightSampler::PMF)
[CudaDeviceExport] public func childShare(first: LightBounds, second: LightBounds, p: float3, normal: float3, child: uint) -> float {
    let shares: float2 = float2(importance(first, p, normal), importance(second, p, normal));
    return select(0.0f, shares[child] / (shares.x + shares.y), shares[child] > 0.0f);
}

// w = a^2 / (a^2 + b^2) = 1 / (1 + (b / a)^2) (Veach 1997)
[CudaDeviceExport] public func powerHeuristic(a: float, b: float) -> float {
    return select(1.0f, 1.0f / (1.0f + (b / a) * (b / a)), b > 0.0f);
}

// Uniform over the cone the sphere subtends: PDF = 1 / (2 * PI * (1 - cos_theta_max)), 1 / (4 * PI) inside
[CudaDeviceExport] public func sphereDensity(center: float3, radius: float, p: float3) -> float {
    // sin^2(theta_max) = radius^2 / distance^2
    let sin2: float = radius * radius / dot(center - p, center - p);
    if (sin2 >= 1.0f) {
        return 0.25f / PI;
    }
    // 1 - cos_theta_max = sin^2 / (1 + cos_theta_max)
    // => PDF = (1 + cos_theta_max) / (2 * PI * sin^2)
    return (1.0f + sqrt(1.0f - sin2)) / (2.0f * PI * sin2);
}

// Uniform direction in the cone toward the sphere (pbrt-v4 Sphere::Sample by solid angle)
[CudaDeviceExport] public func sampleSphere(center: float3, radius: float, p: float3, u1: float, u2: float) -> float3 {
    let sin2: float = radius * radius / dot(center - p, center - p);
    // 1 - cos_theta = u1 * (1 - cos_theta_max) = u1 * sin^2 / (1 + cos_theta_max), 2 * u1 inside
    let one_minus_cos: float = select(u1 * sin2 / (1.0f + sqrt(max(1.0f - sin2, 0.0f))), 2.0f * u1, sin2 >= 1.0f);
    let sin_theta: float = sqrt(max(one_minus_cos * (2.0f - one_minus_cos), 0.0f));
    let phi: float = 2.0f * PI * u2;
    return tangentToWorld(float3(sin_theta * cos(phi), 1.0f - one_minus_cos, sin_theta * sin(phi)), normalize(center - p));
}

#if FK_RESTIR
public static const float POW32 = 4294967296.0;

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
    // Direction to the light point, radiance / PDF and PDF, 0 for point lights of no radius
    __extern_cpp public float3 dir;
    __extern_cpp public float3 radiance;
    __extern_cpp public float density;
    __extern_cpp public uint random_state;
}

// Whether the material is a thin surface transmitting diffusely
func isTranslucent(material: Material) -> bool {
    return rgb_to_greyscale(material.translucent) > 0.0f;
}

// Light sampling at the vertex the ray left, for MIS of the emission the ray meets
__extern_cpp public struct NEEVertex {
    __extern_cpp public bool none;
    __extern_cpp public float pdf;
    __extern_cpp public float3 origin;
    __extern_cpp public float3 smooth_n;
    __extern_cpp public float3 start;
}

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

// Opaque surfaces face the ray with both normals
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

// Whether the path tracer considers dir to point towards the incorrect side of the surface
func wrongSide(is_inside: bool, refracted: bool, dir: float3, geometry_n: float3) -> bool {
    return (is_inside == refracted) != (dot(dir, geometry_n) > 0.0f);
}
#endif

#if FK_RESTIR
__target_intrinsic(wgsl, "Light")
__target_intrinsic(cuda, "FKLight")
__extern_cpp public struct Light {
    __extern_cpp public float3 position;
    __extern_cpp public float is_area_light;
    __extern_cpp public float3 color;
    __extern_cpp public float intensity;
    __extern_cpp public float variance;
}

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

#if FK_RESTIR
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

#if FK_RESTIR
[ForceInline] uint select(uint f, uint t, bool cond) { return select(cond, t, f); }

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

// Light sampling: a light picked by the light tree, P(light) the product of child shares down to it
// Triangle: uniform point, PDF = solidAngle(P(light))
// Sphere: uniform in its cone, PDF = P(light) * sphereDensity
// radiance = L * T / PDF; sided: light all around, origin lifted to the light's side of the face
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
    // Vector from start to the end of the shadow ray
    var shadow: float3;
    if (leaf.x == 2u) {
        let light: Light = scene.light(leaf.y);
        if (sided) {
            lift_n = smooth_n * sign(dot(geometry_n, light.position - origin));
            start = origin + geometry_offset * lift_n;
        }
        if (light.variance == 0.0f) {
            // Delta light at the center: radiance / PDF = I / (d^2 * P(light))
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
        // Uniform point on the triangle: (1 - sqrt(u), sqrt(u) * (1 - v), sqrt(u) * v)
        let side: float = sqrt(random_side.value);
        let uv: float2 = float2(side * (1.0f - random_along.value), side * random_along.value);
        let point: float3 = mul(float3(1.0f - side, uv), t);
        if (sided) {
            lift_n = smooth_n * sign(dot(geometry_n, point - origin));
            start = origin + geometry_offset * lift_n;
        } else if (!(dot(smooth_n, point - origin) > 0.0f)) {
            return sample;
        }
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

// PDF = solidAngle(P(light)) or P(light) * sphereDensity, P(light) the product of child shares down the trail
// of slot j (pbrt-v4's BVHLightSampler::PMF); with no smooth_n, all around
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

// radiance = L / PDF_light
// neeBSDF = BSDF * n_dot_l / PDF_light * w_power
// => neeBSDF * radiance * PDF_light = BSDF * n_dot_l * L / PDF_light * w_power
// Delta lights or no competing BSDF sample: w_power = 1
func lightBSDF(in_dir: float3, light: TreeSample, smooth_n: float3, geometry_n: float3, material: Material, eta_i: float, eta_o: float, competing: bool, random_state: uint) -> float3 {
    if (!competing || light.density == 0.0f) {
        // Translucent materials transmit past the face too
        if (isTranslucent(material)) {
            return translucentBSDF(in_dir, light.dir, smooth_n, geometry_n, material, eta_i, eta_o, random_state) * light.radiance;
        }
        return BSDF(in_dir, light.dir, smooth_n, geometry_n, material, eta_i, eta_o, random_state) * light.radiance;
    }
    let refracted: bool = dot(geometry_n, - in_dir) * dot(geometry_n, light.dir) <= 0.0f;
    return neeBSDF(in_dir, light.dir, smooth_n, material, eta_i, eta_o, refracted, light.density, true, random_state) * light.radiance * light.density;
}

// Power heuristic of BSDF sampling at the vertex the ray left against light sampling of the point met
func emissionWeight<S: IScene>(scene: S, vertex: NEEVertex, hit: Hit, light_point: float3) -> float {
    if (vertex.none) {
        return 1.0f;
    }
    return powerHeuristic(vertex.pdf, lightPdf(scene, vertex.origin, vertex.smooth_n, vertex.start, scene.lightSlot(hit), light_point));
}
#endif

#if FK_RESTIR
func environmentMapped<S: IScene>(scene: S) -> bool {
    return scene.environmentMapSize().x > 1u && scene.environmentMapSize().y > 1u;
}

// p = p(row) * p(column | row), PDF_st = p * size.x * size.y
// dw = 2 * PI^2 * sin(theta) ds dt, sin(theta) = length(dir.xz)
// => PDF = p * size.x * size.y / (2 * PI^2 * sin(theta))
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
func skyRadiance<S: IScene>(scene: S, origin: float3, surface: Surface, is_inside: bool, dir: float3) -> float3 {
    let inside: bool = is_inside != wrongSide(is_inside, false, dir, surface.geometry_n);
    let ray: Ray = Ray(origin + surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, inside), dir);
    return select(scene.env_map_sample(dir), float3(0.0f), scene.shadowTraverseInstanceBVH(ray, POW32, true));
}

// Next event estimation toward the environment map, drawing a direction by its luminance
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

// neeBSDF by the balance heuristic against the BSDF sampled escape
func skyBSDF(in_dir: float3, dir: float3, surface: Surface, eta: float2, is_inside: bool, pdf: float, random_state: uint) -> float3 {
    let refracted: bool = wrongSide(is_inside, false, dir, surface.geometry_n);
    return neeBSDF(in_dir, dir, surface.smooth_n, surface.material, eta.x, eta.y, refracted, pdf, false, random_state);
}

// w = PDF_lobe / (PDF_lobe + PDF_env), 1 for delta lobes and without environment sampling
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
