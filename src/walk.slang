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
public static const uint STREAM_COVERAGE = 256u;
// flex-cuda-pt's free flights through media, as its walk draws them
public static const uint STREAM_MEDIUM = 320u;
// flex-cuda-pt's tracking of the camera's varying medium to the first hit
public static const uint STREAM_CAMERA = 384u;
// Sky samples apart from flex-cuda-pt's coverage, which draws from 256 as its walk did, so both keep their noise
#ifdef FK_FCPT_WALK
public static const uint STREAM_SKY = 448u;
#else
public static const uint STREAM_SKY = 256u;
#endif
#endif

// Target plumbing: flex-cuda-pt's own Reservoir (renderer.h), by which its host sizes its buffers, the struct for every
// other target; the walk and shift make one only by emptyReservoir and reach rc, a Hit there, only by reservoirHit and
// withReservoirHit
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
#ifdef FK_FCPT_WALK
    // What flex-cuda-pt's varying media emit along the path, which its pixel adds as its first hit's emission, not
    // resampled
    __extern_cpp public float3 glow = float3(0.0f);
    // Whether contributions are only summed, as flex-cuda-pt's walk does with ReSTIR off, its consumer's choice
    __extern_cpp public bool sums = false;
#endif
}
// Adds to a selection's glow, flex-cuda-pt's alone
[ForceInline] func addGlow(inout sel: Selection, glow: float3) {
#ifdef FK_FCPT_WALK
    sel.glow += glow;
#endif
}
// Target plumbing: a selection of zeros, its reservoir flex-cuda-pt's value-initialized, as emptyReservoir's
[ForceInline] public Selection emptySelection() {
    __target_switch {
    case cuda: __intrinsic_asm "Selection{}";
    default: return {};
    }
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
// No hit, as a miss reads
[ForceInline] Hit noHit() { return Hit(float2(0.0f), UINT_MAX, 0u, 0u, 0.0f); }

// Target plumbing: the triangle hit stored in a reservoir's rc, a uint4 (instance, triangle, uv), or flex-cuda-pt's
// Hit, which its adapter reads, and writes through pointers to both; and a reservoir of zeros, flex-cuda-pt's
// value-initialized
[ForceInline] public Hit reservoirHit(Reservoir r) {
    __target_switch {
    case cuda: __intrinsic_asm "fcptReservoirHit($0)";
    default: return Hit(asfloat(r.rc.zw), r.rc.x, r.rc.y, 0u, 0.0f);
    }
}
[ForceInline] public Reservoir emptyReservoir() {
    __target_switch {
    case cuda: __intrinsic_asm "Reservoir{}";
    default: return {};
    }
}
[ForceInline] public void withReservoirHit(inout Reservoir r, __constref Hit hit) {
    __target_switch {
    case cuda: __intrinsic_asm "fcptWithReservoirHit($0, $1)";
    default: r.rc = uint4(hit.instance_index, hit.triangle_index, asuint(hit.uv));
    }
}

__extern_cpp public struct Domain {
    __extern_cpp public float3 x0;
    __extern_cpp public float3 x1;
    __extern_cpp public Hit hit;
#ifdef FK_FCPT_WALK
    // flex-cuda-pt's pixel cone (Akenine-Moller et al. 2019): its width at x0 and the angle it spreads by
    __extern_cpp public float width;
    __extern_cpp public float spread;
#endif
}

// Whether paths carry ray cones, by which flex-cuda-pt's surfaces pick their textures' mip levels, its walk's alone
[ForceInline] public bool coneUsed() {
    __target_switch {
    case wgsl: case glsl: return false;
    default: return true;
    }
}
[ForceInline] func coneOf(dom: Domain) -> float2 {
#ifdef FK_FCPT_WALK
    return float2(dom.width, dom.spread);
#else
    return float2(0.0f);
#endif
}

// No lobe: of a camera ray, as flex-cuda-pt's LOBE_NONE, past its diffuse, refraction and reflection lobes
public static const uint LOBE_NONE = 3u;

// The lobe a ray met at vertex b left the vertex before by, none for camera rays, as flex-cuda-pt's walk shades it
func arrivalLobe(b: uint, prev_lobe: uint) -> uint {
    return select(LOBE_NONE, prev_lobe, b > 0u);
}

// Whether rays travel through media, flex-cuda-pt's walk's alone
[ForceInline] public bool mediaUsed() {
    __target_switch {
    case wgsl: case glsl: return false;
    default: return true;
    }
}

// The media on either side of a hit's face f, as flex-cuda-pt's walk keeps them: those the ray travels in, but a volume
// the face bounds behind it, and none in front of it for a ray leaving the volume along f
__extern_cpp public struct MediumSides {
    __extern_cpp public Medium behind;
    __extern_cpp public Medium front;
    __extern_cpp public uint2 fillings;
    __extern_cpp public float3 face;
}
func mediumSides(surface: Surface, medium: Medium, filling: uint, dir: float3) -> MediumSides {
    var sides: MediumSides = MediumSides(medium, medium, uint2(filling), surface.geometry_n);
#ifdef FK_FCPT_WALK
    if (surface.encloses) {
        sides.behind = surface.volume;
        sides.fillings.x = surface.fills;
        if (dot(dir, surface.geometry_n) > 0.0f) {
            sides.front = {};
            sides.fillings.y = UINT_MAX;
        }
    }
#endif
    return sides;
}
// Whether a ray leaving along dir, by the side of side_n that the faced normal g turns, goes in front of the face
func leavesInFront(face: float3, dir: float3, side_n: float3, g: float3) -> bool {
    return (dot(dir, side_n) > 0.0f) == (dot(g, face) > 0.0f);
}

#ifdef FK_FCPT_WALK
// What flex-cuda-pt's shadow segments read of the vertex they leave: the extinction and varying medium's key on either
// side of the faced normal, the side normal that picks one toward the light, the vertex's depth and arrival lobe
// for the occluders' Light Path inputs, whether it is a surface's, as the hooks take it, and the length and cone width
// of the segment reaching it, for the shading of what it passes
__extern_cpp public struct ShadowContext {
    __extern_cpp public float3 extinction_behind;
    __extern_cpp public float3 extinction_front;
    __extern_cpp public uint2 fillings;
    __extern_cpp public float3 side;
    __extern_cpp public uint depth;
    __extern_cpp public uint lobe;
    __extern_cpp public bool surface;
    __extern_cpp public float length;
    __extern_cpp public float width;
    // Of hair's vertex, whose shadow rays leave from it past its own segment, any side lit
    __extern_cpp public Hit own;
    __extern_cpp public bool fiber;
}
func shadowContext(surface: Surface, turned: bool, side_n: float3, extinction: float3, filling: uint, dir: float3, depth: uint, lobe: uint, length: float, width: float, own: Hit, fiber: bool) -> ShadowContext {
    var faced: Surface = surface;
    faced.geometry_n = select(surface.geometry_n, - surface.geometry_n, turned);
    let sides: MediumSides = mediumSides(faced, Medium(float3(0.0f), extinction), filling, dir);
    // The face's sides as the faced normal sees them
    var context: ShadowContext = ShadowContext(sides.behind.extinction, sides.front.extinction, sides.fillings, side_n, depth, lobe, true, length, width, own, fiber);
    if (turned) {
        context = ShadowContext(sides.front.extinction, sides.behind.extinction, sides.fillings.yx, side_n, depth, lobe, true, length, width, own, fiber);
    }
    return context;
}
#endif

// Free flight through a homogeneous medium of mean scattering coefficient sigma: the distance to the next scattering
// its draw u samples, at density sigma exp(-sigma t)
func freeFlight(u: float, sigma: float) -> float {
    return - log(1.0f - u) / sigma;
}
// The throughput's factor over a distance through a homogeneous medium whose scattering free flight samples by its mean
// sigma: what the medium lets through over what free flight left unscattered, times its scattering over sigma where it
// scatters there, as flex-cuda-pt's walk
func flightWeight(scatter: float3, extinction: float3, sigma: float, distance: float, scatters: bool) -> float3 {
    let passed: float3 = exp((float3(sigma) - extinction) * distance);
    return select(passed, scatter * passed / sigma, scatters);
}
// The vertex a ray scattered at, for what follows it: never reconnected at, and no density against the sky, which no
// scattering vertex samples, so that an escape after it takes the whole sky; emission met next weighs against the light
// sampled there by its nee_vertex, of the phase function's density 1 / (4 pi)
func scatteredVertex(is_inside: bool) -> Vertex {
    return Vertex(false, LOBE_DIFFUSE, 0.0f, 1.0f, is_inside);
}
// Whether light is sampled at a scattering vertex b: generating, or replaying at the stop in a homogeneous medium; light
// sampled in a varying medium shifts to no other pixel, as its ratio tracked shadow would differ, as flex-cuda-pt's walk
func scatterSampled(replay: bool, b: uint, stop: uint, varying: bool) -> bool {
    return !replay || (b == stop && !varying);
}
// A direction the isotropic phase function samples, at density 1 / (4 pi)
func isotropic(random_state: uint) -> float3 {
    let u: Random = pcg(random_state);
    let v: Random = pcg(u.state);
    let z: float = 1.0f - 2.0f * u.value;
    let r: float = sqrt(max(1.0f - z * z, 0.0f));
    let angle: float = 2.0f * PI * v.value;
    return float3(r * cos(angle), r * sin(angle), z);
}

// Whether materials may have layers, which a ray meets in turn at one hit, flex-cuda-pt's walk's alone
[ForceInline] public bool layersUsed() {
    __target_switch {
    case wgsl: case glsl: return false;
    default: return true;
    }
}

// Whether a ray leaving a hit of a material of so many layers meets its other layer there: refracting into it from
// outside, or reflecting between them, as flex-cuda-pt's walk
func passesLayer(layers: uint, refracting: bool, passed: bool) -> bool {
    return layers > 1u && refracting != passed;
}

// Inside at a layer the ray passed on to: arriving from behind its face, as flex-cuda-pt decides by the face's side, so
// that a refraction into the layer above, which turns FlexLight's toggle, leaves the layer below met from outside
func arrivesBehind(dir: float3, n: float3) -> bool {
    return dot(dir, n) > 0.0f;
}

// Only the top layer emits, where the ray first meets it
func emitting(surface: Surface, top: bool) -> Surface {
    var lower: Surface = surface;
    lower.material.emissive = select(surface.material.emissive, float3(0.0f), !top);
    return lower;
}

// A cone's spread after a bounce: widened by the angle of the solid angle the lobe's density spans, up to all around;
// delta lobes keep it, as flex-cuda-pt's walk
func widened(spread: float, pdf: float, delta: bool) -> float {
    return spread + select(0.0f, min(2.0f * sqrt(1.0f / (PI * pdf)), PI), !delta);
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
#ifdef FK_FCPT_WALK
    // With ReSTIR off, a path's contributions are only summed, as flex-cuda-pt's resample (renderer.cu 1206-1211); the
    // field alone exists in its variant, so its code goes with it
    if (sel.sums) {
        sel.color += weight;
        return;
    }
#endif
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

// flex-cuda-pt's homogeneous medium: its scattering and extinction coefficients, none by default; flex-cuda-pt's
// FKMedium, as Hit
__target_intrinsic(cuda, "FKMedium")
__extern_cpp public struct Medium {
    __extern_cpp public float3 scatter = float3(0.0f);
    __extern_cpp public float3 extinction = float3(0.0f);
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
#ifdef FK_FCPT_WALK
    // flex-cuda-pt's alpha: the share of rays the surface stops, the rest passing straight through
    __extern_cpp public float coverage = 1.0f;
    // flex-cuda-pt's volumes: whether the face bounds one, its medium behind the face, and the key of the material of a
    // varying one, else UINT_MAX
    __extern_cpp public bool encloses = false;
    __extern_cpp public Medium volume;
    __extern_cpp public uint fills = UINT_MAX;
    // flex-cuda-pt's hair: its fiber's tangent, of the length of its table's level plus one, else none
    __extern_cpp public float3 hair = float3(0.0f);
#endif
}

// Whether surfaces may be partly covered, flex-cuda-pt's alone, compiled out of FlexLight's walk
[ForceInline] public bool coverageUsed() {
    __target_switch {
    case wgsl: case glsl: return false;
    default: return true;
    }
}
[ForceInline] func coverageOf(surface: Surface) -> float {
#ifdef FK_FCPT_WALK
    return surface.coverage;
#else
    return 1.0f;
#endif
}

// Where coverage's draw u leaves a surface uncovered: straight through it at index of refraction 1, its emission and
// absorption kept, as flex-cuda-pt's walk
func uncovered(surface: Surface, u: float) -> Surface {
    if (!coverageUsed() || u < coverageOf(surface)) {
        return surface;
    }
    var material: Material = {};
    material.albedo = float3(1.0f);
    material.emissive = surface.material.emissive;
    material.transmission = 1.0f;
    material.ior = 1.0f;
    material.absorption = surface.material.absorption;
    var through: Surface = surface;
    through.material = material;
    return through;
}

// Surfaces transmitting nothing face the ray along dir with both normals, as in flex-cuda-pt's walk and Cycles
func facingRay(surface: Surface, dir: float3) -> Surface {
    let facing: float = facingSign(surface.material.transmission, surface.geometry_n, dir);
#ifdef FK_FCPT_WALK
    var faced: Surface = surface;
    faced.smooth_n = surface.smooth_n * facing;
    faced.geometry_n = surface.geometry_n * facing;
    return faced;
#else
    return Surface(surface.smooth_n * facing, surface.geometry_n * facing, surface.geometry_offset, surface.material, surface.skip, surface.random_state);
#endif
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
// traverseInstanceBVH's and shadowTransmittanceIn's surface whether the ray leaves a surface, which the consumer starts
// it past by its own margin, or a medium vertex, which it starts right at, so it meets an exit face nearer than that;
// traverseInstanceBVH's left the hit a ray leaves by passing straight through it, its distance the segment that reached
// it, which flex-cuda-pt's traversal skips, else none (instance UINT_MAX); shadowTransmittanceIn's left the hit its
// shadow ray skips, a fiber's own segment, else none; its viewed whether the ray still sees straight
// from the camera, where flex-cuda-pt's traversal passes surfaces hidden from the camera as its camera rays do;
// lightNode(n) the leaf texel of node n of the light BVH (x zero for inner nodes, two for point lights, y the light or
// instance, z the triangle), lightSecond(n) its second child, light(i) point light i, triangleOffset(i) the first
// prototype triangle of instance i, lightTrail(j) the texel of the trail of slot j (x, y its bits) and
// slotLeaf(n, j, trail_texel) whether node n is its leaf,
// environmentCdf(cell) and environmentCdfSize() the environment map's luminance distribution, environmentMapSize() and
// ambient() its size and the color without one, maxBounces() the bounces of a path; renderSize(), frame(), the views
// and camera positions of this frame and the last, pairing(texel, t) reuse texture t, reservoirPrevious(q, layer) a
// layer of last frame's reservoir at q, and previousDomain(q) the primary hit q had, the consumer's own;
// restirNeighbours() the spatial partners, the reservoirs of last frame, of this frame's initial and temporal round and
// the primary hits stored with the latter two, and the shift queue, FlexLight's ShiftQueue: its bins' job counts and
// cursors, its jobs, the size of the indirect dispatch running them, and queuedShifts(i) the same buffer read only;
// currentDomain(p, dom) the primary hit of p this frame, the consumer's own, the passes' uniforms, the stores of the
// reservoirs of each round, of last frame's uv and of the shifts and duplication map, and the color written
public interface IScene {
    public Hit traverseInstanceBVH(Ray ray, bool consider_point_lights, float max_len, bool surface, Hit left, bool viewed);
    public float3 shadowTransmittance(Ray ray, float l);
    public float3 shadowTransmittanceIn(Ray ray, float l, float3 extinction, uint filling, uint random_state, uint depth, uint lobe, bool surface, float length, float width, Hit left);
    public Surface surfaceAt(Hit hit, float3 origin, uint init_random_state);
    public SampleBSDF connectHair(float3 hair, float3 albedo, float3 tint, float3 in_dir, float3 out_dir);
    public SampleBSDF sampleHair(float3 hair, float3 albedo, float3 tint, float3 in_dir, uint random_state);
    public Surface lightSurfaceAt(Hit hit, float3 point, uint init_random_state, float3 dir, uint depth, float length);
    public Surface surfaceAtPath(Hit hit, float3 origin, uint init_random_state, float width, uint layer, uint depth, uint lobe, float3 dir);
    public uint layers(Hit hit);
    public float majorant(uint filling);
    public Medium cameraMedium(float3 direction, float distance, out uint filling);
    public float trackMedium(uint filling, float3 origin, float3 dir, float distance, inout uint random_state, inout float3 weight, inout float3 glowed, inout float3 scatter, inout float3 extinction, uint depth, uint lobe, bool camera);
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
    public float3 env_map_sample(float3 dir, uint depth, uint lobe);
    public float4 environmentCdf(uint2 cell);
    public uint2 environmentCdfSize();
    public uint2 environmentMapSize();
    public float3 ambient();
    public uint maxBounces();
    // What only the passes call
#ifdef FK_RESTIR_PASSES
    public uint2 renderSize();
    public uint frame();
    public float3x3 viewMatrix();
    public float3 cameraPosition();
    public float3x3 prevViewMatrix();
    public float3 prevCameraPosition();
    public int4 pairing(int2 texel, uint t);
    public uint4 reservoirPrevious(int2 q, uint layer);
    public Domain previousDomain(int2 q);
    public uint restirNeighbours();
    public Reservoir loadReservoirPrevious(int2 q);
    public Reservoir loadReservoirInitial(int2 p);
    public Reservoir loadReservoirTemporal(int2 p);
    public bool storedDomainInitial(int2 p, out Domain dom);
    public bool storedDomainTemporal(int2 p, out Domain dom);
    public uint queueCountAdd(uint bin, uint jobs);
    public uint queueCountLoad(uint bin);
    public uint queueCursorAdd(uint bin, uint jobs);
    public void queueJobStore(uint index, uint job);
    public void queueDispatchStore(uint x, uint y, uint z);
    public uint queuedShifts(uint index);
    public bool currentDomain(int2 p, out Domain dom);
    public uint samples();
    public uint restirDecorrelation();
    public uint isTemporal();
    public float3x3 invViewMatrix();
    public void storeReservoirInitial(int2 p, Reservoir r, Hit x1);
    public void storeReservoirTemporal(int2 p, Reservoir r, Hit x1);
    public void storeReservoirPrevious(int2 p, Reservoir r, Hit x1);
    public void storePreviousLayer(int2 p, uint layer, uint4 value);
    public uint4 duplication(int2 q);
    public void storeDuplication(int2 p, uint4 value);
    public uint4 temporalShift(int2 p, uint layer);
    public void storeTemporalShift(int2 p, uint layer, uint4 value);
    public uint4 shiftData(int2 p, uint layer);
    public void storeShiftData(int2 p, uint layer, uint4 value);
    public uint4 reservoirTemporal(int2 q, uint layer);
    public void storeColor(int2 p, uint layer, float4 color);
#endif
}
#endif

#ifdef FK_RESTIR
// Target plumbing: the scene of the ReSTIR variant outputs, each method FlexLight's own function or the read of its
// buffer it stands for in its shader, and flex-cuda-pt's function of the name its adapter defines, in place of a call
public struct HookScene : IScene {
    __target_intrinsic(wgsl, "traverseInstanceBVH($0, $1, $2)")
    __target_intrinsic(cuda, "fcptTraverseInstanceBVH($0, $1, $2, $3, $4, $5)")
    public Hit traverseInstanceBVH(Ray ray, bool consider_point_lights, float max_len, bool surface, Hit left, bool viewed);
    __target_intrinsic(wgsl, "shadowTransmittance($0, $1)")
    __target_intrinsic(cuda, "fcptShadowTransmittance($0, $1)")
    public float3 shadowTransmittance(Ray ray, float l);
    // Through the media from the start's side on, ratio tracking a varying one with the light pick's random state;
    // occluders shaded for a shadow ray a bounce past the vertex, the medium for the length and cone width of the
    // segment reaching it. flex-cuda-pt's alone
    __target_intrinsic(wgsl, "shadowTransmittance($0, $1)")
    __target_intrinsic(cuda, "fcptShadowTransmittanceIn($0, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10)")
    public float3 shadowTransmittanceIn(Ray ray, float l, float3 extinction, uint filling, uint random_state, uint depth, uint lobe, bool surface, float length, float width, Hit left);
    __target_intrinsic(wgsl, "surfaceAt($0, $1, $2)")
    __target_intrinsic(cuda, "fcptSurfaceAt($0, $1, $2)")
    public Surface surfaceAt(Hit hit, float3 origin, uint init_random_state);
    // flex-cuda-pt's hair, by its fiber's baked far field of hair, its albedo and its R lobe's tint: toward out_dir, its
    // f over its density as throughput and its density over the light's cosine as pdf; and a direction it samples
    __target_intrinsic(wgsl, "SampleBSDF()")
    __target_intrinsic(cuda, "fcptConnectHair($0, $1, $2, $3, $4)")
    public SampleBSDF connectHair(float3 hair, float3 albedo, float3 tint, float3 in_dir, float3 out_dir);
    __target_intrinsic(wgsl, "SampleBSDF()")
    __target_intrinsic(cuda, "fcptSampleHair($0, $1, $2, $3, $4)")
    public SampleBSDF sampleHair(float3 hair, float3 albedo, float3 tint, float3 in_dir, uint random_state);
    // A light sample's surface as flex-cuda-pt shades its emission: seen along dir from the start, of the depth of the
    // vertex sampling it, at length from that vertex. flex-cuda-pt's alone
    __target_intrinsic(wgsl, "surfaceAt($0, $1, $2)")
    __target_intrinsic(cuda, "fcptLightSurfaceAt($0, $1, $2, $3, $4, $5)")
    public Surface lightSurfaceAt(Hit hit, float3 point, uint init_random_state, float3 dir, uint depth, float length);
    // The surface as the path meets it: mip levels by its cone's width at the hit, the layer of the hit's material, and
    // for Light Path nodes the ray's bounce depth and the lobe it left the vertex before by (LOBE_NONE from the camera),
    // and the ray's own direction, which flex-cuda-pt shades by; FlexLight's has none of them
    __target_intrinsic(wgsl, "surfaceAt($0, $1, $2)")
    __target_intrinsic(cuda, "fcptSurfaceAtPath($0, $1, $2, $3, $4, $5, $6, $7)")
    public Surface surfaceAtPath(Hit hit, float3 origin, uint init_random_state, float width, uint layer, uint depth, uint lobe, float3 dir);
    // How many layers the hit's material has, flex-cuda-pt's alone
    __target_intrinsic(wgsl, "1u")
    __target_intrinsic(cuda, "fcptLayers($0)")
    public uint layers(Hit hit);
    // Of the varying medium whose material key is filling, flex-cuda-pt's alone: its majorant, and the distance along
    // the ray to its next real scattering by spectral tracking under it (past distance for none), the weight of the
    // tentative collisions passed and the emission gathered on the way accumulating, and its coefficients taken where
    // it scatters
    __target_intrinsic(wgsl, "0.0f")
    __target_intrinsic(cuda, "fcptMajorant($0)")
    public float majorant(uint filling);
    // The medium the camera is in, flex-cuda-pt's alone, shaded along the camera ray's direction and distance: its
    // coefficients and its material's key if varying, else UINT_MAX
    __target_intrinsic(wgsl, "Medium()")
    __target_intrinsic(cuda, "fcptCameraMedium($0, $1, $2)")
    public Medium cameraMedium(float3 direction, float distance, out uint filling);
    __target_intrinsic(wgsl, "0.0f")
    __target_intrinsic(cuda, "fcptTrackMedium($0, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)")
    public float trackMedium(uint filling, float3 origin, float3 dir, float distance, inout uint random_state, inout float3 weight, inout float3 glowed, inout float3 scatter, inout float3 extinction, uint depth, uint lobe, bool camera);
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
    __target_intrinsic(cuda, "fcptEnvMapSample($0, $1, $2)")
    public float3 env_map_sample(float3 dir, uint depth, uint lobe);
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
#ifdef FK_RESTIR_PASSES
    __target_intrinsic(wgsl, "uniforms_uint.render_size")
    __target_intrinsic(cuda, "fcptRenderSize()")
    public uint2 renderSize();
    __target_intrinsic(wgsl, "uniforms_uint.frame")
    __target_intrinsic(cuda, "fcptFrame()")
    public uint frame();
    __target_intrinsic(wgsl, "uniforms_float.view_matrix")
    __target_intrinsic(cuda, "fcptViewMatrix()")
    public float3x3 viewMatrix();
    __target_intrinsic(wgsl, "uniforms_float.camera_position")
    __target_intrinsic(cuda, "fcptCameraPosition()")
    public float3 cameraPosition();
    __target_intrinsic(wgsl, "uniforms_float.prev_view_matrix")
    __target_intrinsic(cuda, "fcptPrevViewMatrix()")
    public float3x3 prevViewMatrix();
    __target_intrinsic(wgsl, "uniforms_float.prev_camera_position")
    __target_intrinsic(cuda, "fcptPrevCameraPosition()")
    public float3 prevCameraPosition();
    __target_intrinsic(wgsl, "textureLoad(pairing, $0, $1, 0)")
    __target_intrinsic(cuda, "fcptPairing($0, $1)")
    public int4 pairing(int2 texel, uint t);
    __target_intrinsic(wgsl, "textureLoad(reservoir_prev, $0, $1, 0)")
    __target_intrinsic(cuda, "fcptReservoirPrevious($0, $1)")
    public uint4 reservoirPrevious(int2 q, uint layer);
    __target_intrinsic(wgsl, "previousDomain($0)")
    __target_intrinsic(cuda, "fcptPreviousDomain($0)")
    public Domain previousDomain(int2 q);
    __target_intrinsic(wgsl, "uniforms_uint.restir_neighbours")
    __target_intrinsic(cuda, "fcptRestirNeighbours()")
    public uint restirNeighbours();
    __target_intrinsic(wgsl, "loadReservoir(reservoir_prev, $0)")
    __target_intrinsic(cuda, "fcptLoadReservoirPrevious($0)")
    public Reservoir loadReservoirPrevious(int2 q);
    __target_intrinsic(wgsl, "loadReservoir(reservoir_initial, $0)")
    __target_intrinsic(cuda, "fcptLoadReservoirInitial($0)")
    public Reservoir loadReservoirInitial(int2 p);
    __target_intrinsic(wgsl, "loadReservoir(reservoir_temp, $0)")
    __target_intrinsic(cuda, "fcptLoadReservoirTemporal($0)")
    public Reservoir loadReservoirTemporal(int2 p);
    __target_intrinsic(wgsl, "storedDomain(reservoir_initial, $0, &$1)")
    __target_intrinsic(cuda, "fcptStoredDomainInitial($0, $1)")
    public bool storedDomainInitial(int2 p, out Domain dom);
    __target_intrinsic(wgsl, "storedDomain(reservoir_temp, $0, &$1)")
    __target_intrinsic(cuda, "fcptStoredDomainTemporal($0, $1)")
    public bool storedDomainTemporal(int2 p, out Domain dom);
    __target_intrinsic(wgsl, "atomicAdd(&shift_queue.counts[$0], $1)")
    __target_intrinsic(cuda, "fcptQueueCountAdd($0, $1)")
    public uint queueCountAdd(uint bin, uint jobs);
    __target_intrinsic(wgsl, "atomicLoad(&shift_queue.counts[$0])")
    __target_intrinsic(cuda, "fcptQueueCountLoad($0)")
    public uint queueCountLoad(uint bin);
    __target_intrinsic(wgsl, "atomicAdd(&shift_queue.cursors[$0], $1)")
    __target_intrinsic(cuda, "fcptQueueCursorAdd($0, $1)")
    public uint queueCursorAdd(uint bin, uint jobs);
    __target_intrinsic(wgsl, "shift_queue.jobs[$0] = $1")
    __target_intrinsic(cuda, "fcptQueueJobStore($0, $1)")
    public void queueJobStore(uint index, uint job);
    __target_intrinsic(wgsl, "shift_queue.dispatch = array<u32, 3>($0, $1, $2)")
    __target_intrinsic(cuda, "fcptQueueDispatchStore($0, $1, $2)")
    public void queueDispatchStore(uint x, uint y, uint z);
    __target_intrinsic(wgsl, "queued_shifts[$0]")
    __target_intrinsic(cuda, "fcptQueuedShifts($0)")
    public uint queuedShifts(uint index);
    __target_intrinsic(wgsl, "currentDomain($0, &$1)")
    __target_intrinsic(cuda, "fcptCurrentDomain($0, $1)")
    public bool currentDomain(int2 p, out Domain dom);
    __target_intrinsic(wgsl, "uniforms_uint.samples")
    __target_intrinsic(cuda, "fcptSamples()")
    public uint samples();
    __target_intrinsic(wgsl, "uniforms_uint.restir_decorrelation")
    __target_intrinsic(cuda, "fcptRestirDecorrelation()")
    public uint restirDecorrelation();
    __target_intrinsic(wgsl, "uniforms_uint.is_temporal")
    __target_intrinsic(cuda, "fcptIsTemporal()")
    public uint isTemporal();
    __target_intrinsic(wgsl, "uniforms_float.inv_view_matrix")
    __target_intrinsic(cuda, "fcptInvViewMatrix()")
    public float3x3 invViewMatrix();
    __target_intrinsic(wgsl, "storeReservoir(reservoir_initial_out, $0, $1, $2)")
    __target_intrinsic(cuda, "fcptStoreReservoirInitial($0, $1, $2)")
    public void storeReservoirInitial(int2 p, Reservoir r, Hit x1);
    __target_intrinsic(wgsl, "storeReservoir(reservoir_temp_out, $0, $1, $2)")
    __target_intrinsic(cuda, "fcptStoreReservoirTemporal($0, $1, $2)")
    public void storeReservoirTemporal(int2 p, Reservoir r, Hit x1);
    __target_intrinsic(wgsl, "storeReservoir(reservoir_prev_out, $0, $1, $2)")
    __target_intrinsic(cuda, "fcptStoreReservoirPrevious($0, $1, $2)")
    public void storeReservoirPrevious(int2 p, Reservoir r, Hit x1);
    __target_intrinsic(wgsl, "textureStore(reservoir_prev_out, $0, $1, $2)")
    __target_intrinsic(cuda, "fcptStorePreviousLayer($0, $1, $2)")
    public void storePreviousLayer(int2 p, uint layer, uint4 value);
    __target_intrinsic(wgsl, "textureLoad(duplication, $0, 0, 0)")
    __target_intrinsic(cuda, "fcptDuplication($0)")
    public uint4 duplication(int2 q);
    __target_intrinsic(wgsl, "textureStore(duplication_out, $0, 0, $1)")
    __target_intrinsic(cuda, "fcptStoreDuplication($0, $1)")
    public void storeDuplication(int2 p, uint4 value);
    __target_intrinsic(wgsl, "textureLoad(temporal_shifts, $0, $1, 0)")
    __target_intrinsic(cuda, "fcptTemporalShift($0, $1)")
    public uint4 temporalShift(int2 p, uint layer);
    __target_intrinsic(wgsl, "textureStore(temporal_shifts_out, $0, $1, $2)")
    __target_intrinsic(cuda, "fcptStoreTemporalShift($0, $1, $2)")
    public void storeTemporalShift(int2 p, uint layer, uint4 value);
    __target_intrinsic(wgsl, "textureLoad(shift_data, $0, $1, 0)")
    __target_intrinsic(cuda, "fcptShiftData($0, $1)")
    public uint4 shiftData(int2 p, uint layer);
    __target_intrinsic(wgsl, "textureStore(shift_data_out, $0, $1, $2)")
    __target_intrinsic(cuda, "fcptStoreShiftData($0, $1, $2)")
    public void storeShiftData(int2 p, uint layer, uint4 value);
    __target_intrinsic(wgsl, "textureLoad(reservoir_temp, $0, $1, 0)")
    __target_intrinsic(cuda, "fcptReservoirTemporal($0, $1)")
    public uint4 reservoirTemporal(int2 q, uint layer);
    __target_intrinsic(wgsl, "textureStore(compute_out, $0, $1, $2)")
    __target_intrinsic(cuda, "fcptStoreColor($0, $1, $2)")
    public void storeColor(int2 p, uint layer, float4 color);
#endif
}
#endif

#ifdef FK_RESTIR
// Target plumbing: WGSL's select of uints, in its argument order f, t, cond, as pathtracer.slang's of floats, which
// uints would otherwise reach through float
[ForceInline] uint select(uint f, uint t, bool cond) { return select(cond, t, f); }

// Shadow test toward a light sample, including the quick exit for lights behind the shading normal, along the shared
// segment: short of its end, which an emitting triangle's sample lifts off it toward the start
func lightTransmittance<S: IScene>(scene: S, origin: float3, smooth_n: float3, geometry_offset: float, light_dir: float3
#ifdef FK_FCPT_WALK
    , context: ShadowContext, random_state: uint
#endif
    ) -> float3 {
    let unit_light_dir: float3 = normalize(light_dir);
    // Compute quick exit criterion to potentially skip expensive shadow test
    if (dot(smooth_n, unit_light_dir) < 0.0f) {
        return float3(0.0f);
    }
    // Apply geometry offset
    let offset_target: float3 = origin + geometry_offset * smooth_n;
    let light_ray: Ray = Ray(offset_target, unit_light_dir);
#ifdef FK_FCPT_WALK
    // From the medium on the side the light is, from the vertex, as flex-cuda-pt's sampleLight
    let front: bool = dot(context.side, light_dir + geometry_offset * smooth_n) > 0.0f;
    return scene.shadowTransmittanceIn(light_ray, shadowLength(light_dir), select(context.extinction_behind, context.extinction_front, front), select(context.fillings.x, context.fillings.y, front), random_state, context.depth, context.lobe, context.surface && !context.fiber, context.length, context.width, context.fiber ? context.own : noHit());
#else
    return scene.shadowTransmittance(light_ray, shadowLength(light_dir));
#endif
}

// Light sampling, as flex-cuda-pt's sampleLight: a light the light BVH picks by its importance to origin, a uniform point
// on it or a direction in the cone of its sphere, seen from origin lifted by geometry_offset in front of smooth_n. Sided,
// for translucent surfaces, light all around, origin lifted to the side of the face geometry_n the light lies on
public func sampleLightTree<S: IScene>(scene: S, origin: float3, smooth_n: float3, geometry_n: float3, geometry_offset: float, sided: bool, init_random_state: uint
#ifdef FK_FCPT_WALK
    , context: ShadowContext
#endif
    ) -> TreeSample {
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
    // Vector from start to the end of the shadow ray, as lightTransmittance() casts it from there
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
#ifdef FK_FCPT_WALK
        let surface: Surface = scene.lightSurfaceAt(Hit(uv, leaf.y, triangle_index, 0u, 0.0f), point, random_along.state,
            normalize(point - start), context.depth, length(point - origin));
#else
        let surface: Surface = scene.surfaceAt(Hit(uv, leaf.y, triangle_index, 0u, 0.0f), point, random_along.state);
#endif
        sample.random_state = surface.random_state;
        sample.dir = normalize(point - start);
        sample.density = solidAngle(probability, cross(t[1] - t[0], t[2] - t[0]), point - start);
#ifdef FK_FCPT_WALK
        // Emitting on both sides, as flex-cuda-pt's emitters and Cycles': a one-sided light is one by what it exports
        // behind it
        sample.radiance = select(surface.material.emissive, float3(0.0f), surface.skip) / sample.density;
#else
        sample.radiance = select(surface.material.emissive * max(sign(dot(- sample.dir, surface.smooth_n)), 0.0f), float3(0.0f), surface.skip) / sample.density;
#endif
        shadow = point + shadowLift(surface.smooth_n, surface.geometry_offset, start, point) - start;
    }
    let transmitted: float3 = lightTransmittance(scene, origin, lift_n, geometry_offset, shadow
#ifdef FK_FCPT_WALK
        , context, random_along.state
#endif
        );
    sample.radiance = select(sample.radiance * transmitted, float3(0.0f), all(transmitted == float3(0.0f)));
    return sample;
}

// Density in solid angle of light sampling from origin, lifted to start, picking point on the light of trail slot j, down
// its trail (pbrt-v4's BVHLightSampler::PMF), as flex-cuda-pt's lightPdf; with no smooth_n, sided, all around
public func lightPdf<S: IScene>(scene: S, origin: float3, smooth_n: float3, start: float3, j: uint, light_point: float3) -> float {
#ifdef FK_FCPT_WALK
    // Of no slot, a light no light sampling picks (flex-cuda-pt's strands): its BSDF hit weighs fully
    if (j == UINT_MAX) {
        return 0.0f;
    }
#endif
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

// at hair, of flex-cuda-pt's walk, the first, else the second; on other targets, which have no hair, the second alone
#ifdef FK_FCPT_WALK
#define AT_HAIR(at_hair, elsewhere) (hair ? (at_hair) : (elsewhere))
#else
#define AT_HAIR(at_hair, elsewhere) (elsewhere)
#endif

#ifdef FK_FCPT_WALK
// Hair's light sample, as flex-cuda-pt's walk weighs it: its far field toward the light against sampling it, by the
// power heuristic, where a direction it samples competes; a delta light, of no density, weighs fully
func hairLight<S: IScene>(scene: S, surface: Surface, in_dir: float3, light: TreeSample, competing: bool) -> float3 {
    let l: SampleBSDF = scene.connectHair(surface.hair, surface.material.albedo, surface.material.specular_tint, in_dir, light.dir);
    return l.throughput * l.pdf / select(1.0f, 1.0f + l.pdf * l.pdf / (light.density * light.density), competing && light.density > 0.0f) * light.radiance;
}
#endif

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
// Whether light sampling draws the environment: where it has a map, which in FlexLight always comes with its luminance
// distribution, and in flex-cuda-pt only with one once its world has it
func environmentMapped<S: IScene>(scene: S) -> bool {
#ifdef FK_FCPT_WALK
    if (!(scene.environmentCdfSize().x > 1u && scene.environmentCdfSize().y > 1u)) {
        return false;
    }
#endif
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
    // Of no Light Path context: flex-cuda-pt samples no sky before its world has a luminance CDF
    return scene.env_map_sample(dir, 0u, LOBE_NONE) * scene.shadowTransmittance(ray, POW32);
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

// Toward dir, for flex-cuda-pt's world shader from the depth and lobe of the vertex the ray left
func environment<S: IScene>(scene: S, dir: float3
#ifdef FK_FCPT_WALK
    , depth: uint, lobe: uint
#endif
    ) -> float3 {
    if (scene.environmentMapSize().x > 1u && scene.environmentMapSize().y > 1u) {
#ifdef FK_FCPT_WALK
        return scene.env_map_sample(dir, depth, lobe);
#else
        return scene.env_map_sample(dir, 0u, LOBE_NONE);
#endif
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

// The medium between ray.origin and hit, of which a path at vertex b crosses into the next: scattering at distances
// as the walk's own loop did there. True where the walk ends, with ended its result
[ForceInline] func crossMedium<S: IScene>(scene: S, r: Reservoir, replay: bool, stop: uint, rc: uint, scale: float,
    chain: Reservoir, chain_throughput: float3, is_inside: bool, filling: uint, inout b: uint, inout ray: Ray,
    inout hit: Hit, inout throughput: float3, inout density: float, inout weight: float3, inout glowed: float3,
    inout scatter_in: float3, inout extinction_in: float3, inout width: float, inout spread: float, inout prev: Vertex,
    inout nee_vertex: NEEVertex, inout sky_pdf: float, inout sel: Selection, out ended: Shift) -> bool {
    ended = Shift(float3(0.0f), 0.0f);
    // Before the hit, the medium scatters the ray at distances its mean scattering coefficient samples, or a
    // varying one's tracking under its majorant does, at vertices leaving by the isotropic phase function,
    // which ReSTIR neither reconnects at nor across
    let varying: bool = filling != UINT_MAX;
    let sigma: float = select((scatter_in.x + scatter_in.y + scatter_in.z) / 3.0f, scene.majorant(filling), varying);
    if (replay && b == stop && rc == RC_SURFACE && sigma > 0.0f) {
        return true;
    }
    prev.rough = prev.rough && !(sigma > 0.0f);
    // From the camera (b UINT_MAX) at its own stream, of depth 0 and no lobe
    var tracking: uint = stream(r.seed, select(b + STREAM_MEDIUM, STREAM_CAMERA, b == UINT_MAX));
    // A varying medium's tentative collisions passed and what it emits along the ray to the next
    weight = float3(1.0f);
    glowed = float3(0.0f);
    while (hit.instance_index != UINT_MAX) {
        var along: float = freeFlight(pcg(stream(r.seed, select(b + STREAM_MEDIUM, STREAM_CAMERA,
            b == UINT_MAX))).value, sigma);
        if (varying) {
            along = scene.trackMedium(filling, ray.origin, ray.unit_direction, hit.distance, tracking, weight, glowed,
                scatter_in, extinction_in, select(b, 0u, b == UINT_MAX), select(prev.lobe, LOBE_NONE, b == UINT_MAX),
                b == UINT_MAX);
        }
        if (!(along < hit.distance)) {
            break;
        }
        if (varying && !replay) {
            addGlow(sel, throughput * glowed / density);
        }
        glowed = float3(0.0f);
        b++;
        ray.origin += along * ray.unit_direction;
        throughput *= select(flightWeight(scatter_in, extinction_in, sigma, along, true), weight, varying);
        tracking = stream(r.seed, b + STREAM_MEDIUM);
        weight = float3(1.0f);
        if (coneUsed()) {
            width += spread * along;
            spread += PI;
        }
        // Light sampled there, without a surface: from the vertex itself, all around, through the medium on both
        // its sides, against the isotropic phase function by the power heuristic, as flex-cuda-pt's walk
        let light: TreeSample = sampleLightTree(scene, ray.origin, ray.unit_direction, ray.unit_direction, 0.0f, true, stream(r.seed, b + STREAM_NEE)
#ifdef FK_FCPT_WALK
            , ShadowContext(extinction_in, extinction_in, uint2(filling), ray.unit_direction, b,
                arrivalLobe(b, prev.lobe), false, along, width,
                noHit(), false)
#endif
            );
        let sampled: bool = scatterSampled(replay, b, stop, varying);
        // A delta light, of no density, the phase function never samples: its light sample weighs fully
        let competing: float = select(0.0f, 0.25f * INV_PI, b < scene.maxBounces() && light.density > 0.0f);
        let f: float3 = select(float3(0.0f), throughput * light.radiance * (0.25f * INV_PI
            * powerHeuristic(light.density, competing)), sampled);
        if (replay && b == stop) {
            if (rc == RC_LIGHT && rgb_to_greyscale(f) > 0.0f) {
                ended = Shift(f, 1.0f);
                return true;
            }
            return true;
        }
        if (!replay) {
            var candidate: Reservoir = chain;
            if (extractBits(chain.path, PATH_RC, 2u) == RC_SURFACE) {
                candidate.radiance = safeDivide(f, chain_throughput);
            } else {
                candidate.path = insertBits(insertBits(0u, b + 1u, PATH_K, 5u), RC_LIGHT, PATH_RC, 2u);
            }
            offer(sel, withEnd(candidate, END_NEE, b, f), f * scale / density);
            let survival_probability: float = survivalProbability(throughput, density);
            if (survival_probability < pcg(stream(r.seed, b + STREAM_RR)).value || b >= scene.maxBounces()) {
                return true;
            }
            density *= survival_probability;
        }
        // Emission met next is weighed against the light sampled here
        nee_vertex = NEEVertex(false, 0.25f * INV_PI, ray.origin, float3(0.0f), ray.origin);
        ray.unit_direction = isotropic(stream(r.seed, b));
        prev = scatteredVertex(is_inside);
        sky_pdf = prev.pdf;
        hit = scene.traverseInstanceBVH(ray, true, POW32, false, noHit(), false);
    }
    return false;
}

// The ray reaching hit across the medium it crossed: escaping on a miss, where the walk ends, else moved to the hit
// with what the medium let through. True where the walk ends, with ended its result
[ForceInline] func arrive<S: IScene>(scene: S, r: Reservoir, replay: bool, stop: uint, rc: uint, end: uint,
    end_type: uint, scale: float, b: uint, chain: Reservoir, chain_throughput: float3, nee_vertex: NEEVertex,
    prev: Vertex, sky_pdf: float, density: float, hit: Hit, filling: uint, scatter_in: float3, extinction_in: float3,
    weight: float3, glowed: float3, spread: float, inout ray: Ray, inout throughput: float3, inout width: float,
    inout sel: Selection, out ended: Shift) -> bool {
    ended = Shift(float3(0.0f), 0.0f);
    if (hit.instance_index == UINT_MAX) {
        // BSDF sampled escapes share the environment with its next event estimation
        let weight: float = escapeWeight(scene, select(0.0f, sky_pdf, !nee_vertex.none), ray.unit_direction);
        let f: float3 = throughput * environment(scene, ray.unit_direction
#ifdef FK_FCPT_WALK
            , b, prev.lobe
#endif
            );
        if (replay) {
            if (b == stop && rc == RC_ENV) {
                ended = Shift(f * weight / r.jac, density / r.jac);
                return true;
            }
            if (rc == RC_NONE && end_type == END_ENV && b == end && !prev.rough) {
                ended = Shift(f * weight, 1.0f);
                return true;
            }
            return true;
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
        return true;
    }
    // Project ray origin to hit point
    ray.origin += hit.distance * ray.unit_direction;
    if (mediaUsed()) {
        // What the medium lets through to the hit, unscattered, and what a varying one emits on the way
        if (filling != UINT_MAX) {
            if (!replay) {
                addGlow(sel, throughput * glowed / density);
            }
            throughput *= weight;
        } else {
            throughput *= flightWeight(scatter_in, extinction_in, (scatter_in.x + scatter_in.y + scatter_in.z) / 3.0f, hit.distance, false);
        }
    }
    if (coneUsed()) {
        width += spread * hit.distance;
    }
    return false;
}

// Walk a path from dom like lightTrace. Generating, every path of the tree is resampled into sel with its reconnection
// vertex (Sec. 6.1), Russian roulette only modifies their source density (Sec. 6.2.4). Replaying, the hybrid shift maps r into
// dom (Sec. 2.3): random replay up to x_k-1 and reconnection to x_k. It returns the shifted integrand times the Jacobian
// determinant of Eq. 2, zero if the path is not in the image of the shift.
public func walk<S: IScene>(scene: S, dom: Domain, r: Reservoir, replay: bool, scale: float, inout sel: Selection) -> Shift {
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
    let rc_hit: Hit = reservoirHit(r);
    var ray: Ray = Ray(dom.x1, normalize(dom.x1 - dom.x0));
    var hit: Hit = dom.hit;
    // The path's cone: its width at the hit, widening by its spread, which each bounce widens
    var spread: float = 0.0f;
    var width: float = 0.0f;
    // Layer of the hit's material the ray meets, and whether it came there from another layer of the hit
    var layer: uint = 0u;
    var passed: bool = false;
    var passes: bool = false;
    // Medium the ray travels in, its extinction (its scattering comes with free flight), the key of its material if
    // varying, else UINT_MAX, and whether facing the ray turned the hit's face: by plain values, as FlexLight's WGSL
    // would carry a struct
    var scatter_in: float3 = float3(0.0f);
    // A varying medium's tracking weight and emission gathered up to the hit
    var weight: float3 = float3(1.0f);
    var glowed: float3 = float3(0.0f);
    var extinction_in: float3 = float3(0.0f);
    var filling: uint = UINT_MAX;
    var turned: bool = false;
    if (coneUsed()) {
        spread = coneOf(dom).y;
        width = coneOf(dom).x + spread * length(dom.x1 - dom.x0);
    }
    var throughput: float3 = float3(1.0f);
    // Replaying the densities of the reconnection, generating the product of Russian roulette survival probabilities
    var density: float = 1.0f;
    var is_inside: bool = false;
#ifdef FK_FCPT_WALK
    // Seen straight from the camera, as flex-cuda-pt's walk keeps it: past refractions at equal indices alone, which bend
    // no ray, and no medium's scattering; where it holds, the trace passes surfaces hidden from the camera
    var viewed: bool = true;
#endif
    // Light sampling at the vertex the ray left, none at the camera
    var nee_vertex: NEEVertex = NEEVertex(true, 0.0f, float3(0.0f), float3(0.0f), float3(0.0f));
    var threshold: float = 0.0f;
    var reconnection: float3 = {};
    var prev: Vertex = {};
    // Density of the direction an escape leaves along, which the escape weighs against sky light sampling
    var sky_pdf: float = 0.0f;
    // Template for generated paths reconnecting at the first vertex meeting both footprint criteria
    var chain: Reservoir = emptyReservoir();
    chain.seed = r.seed;
    var chain_throughput: float3 = float3(0.0f);
    // The camera's medium, which scatters on the way to the first hit as any medium does: vertices there count from
    // b = 0, the camera being the one before them, at UINT_MAX
    var b: uint = UINT_MAX;
    if (mediaUsed()) {
        ray.origin = dom.x0;
        hit.distance = length(dom.x1 - dom.x0);
        let camera: Medium = scene.cameraMedium(ray.unit_direction, hit.distance, filling);
        scatter_in = camera.scatter;
        extinction_in = camera.extinction;
        if (coneUsed()) {
            width = coneOf(dom).x;
        }
        var ended: Shift = {};
#ifdef FK_FCPT_WALK
        let unscattered: uint = b;
#endif
        if (crossMedium(scene, r, replay, stop, rc, scale, chain, chain_throughput, is_inside, filling, b, ray, hit,
            throughput, density, weight, glowed, scatter_in, extinction_in, width, spread, prev, nee_vertex, sky_pdf,
            sel, ended)) {
            return ended;
        }
#ifdef FK_FCPT_WALK
        viewed = viewed && b == unscattered;  // A scattering vertex counts in b
#endif
        if (arrive(scene, r, replay, stop, rc, end, end_type, scale, b, chain, chain_throughput, nee_vertex, prev,
            sky_pdf, density, hit, filling, scatter_in, extinction_in, weight, glowed, spread, ray, throughput, width,
            sel, ended)) {
            return ended;
        }
    }
    // The first surface met, whose footprint bounds reconnections
    let primary: uint = b + 1u;
    for (b = primary; ; b++) {
        let point_light_lighting: bool = hit.is_point_light == 1u;
        // Loop scoped variables are initialized explicitly, some compilers keep the previous iteration's value otherwise
        var surface: Surface = {};
        // Smooth normal the surface emits along, before it faces the ray
        var front_n: float3 = float3(0.0f);
        var scatter: bool = false;
#ifdef FK_FCPT_WALK
        // Leaving by passing straight through the hit, at index of refraction 1, as flex-cuda-pt's walk
        var straight: bool = false;
#endif
        var geometry_density: float = 0.0f;
        if (!point_light_lighting) {
            if (coneUsed() || layersUsed()) {
                surface = scene.surfaceAtPath(hit, ray.origin, stream(r.seed, b), width, layer, b, arrivalLobe(b, prev.lobe), ray.unit_direction);
            } else {
                surface = scene.surfaceAt(hit, ray.origin, stream(r.seed, b));
            }
            if (layersUsed()) {
                surface = emitting(surface, !passed);
            }
            if (coverageUsed()) {
                surface = uncovered(surface, pcg(stream(r.seed, b + STREAM_COVERAGE)).value);
            }
            front_n = surface.smooth_n;
            if (mediaUsed()) {
                turned = facingSign(surface.material.transmission, surface.geometry_n, ray.unit_direction) < 0.0f;
            }
#ifdef FK_FCPT_WALK
            // The side the ray travels on, per hit from its face, as flex-cuda-pt takes a hit's sides: inside a
            // transmitting surface's body where it arrives behind the face, uncovered shares included, and inside none
            // at an opaque one, which faces the ray
            is_inside = surface.material.transmission > 0.0f && arrivesBehind(ray.unit_direction, surface.geometry_n);
#endif
            surface = facingRay(surface, ray.unit_direction);
            if (layersUsed() && passed) {
                is_inside = arrivesBehind(ray.unit_direction, surface.geometry_n);
            }
            if (is_inside) {
                throughput *= beerLambert(hit.distance, surface.material.absorption);
            }
            scatter = !surface.skip;
            geometry_density = geometryDensity(surface.geometry_n, ray.unit_direction, hit.distance);
            if (b == primary) {
                // Primary ray footprint (Eq. 5)
                threshold = footprintThreshold(geometry_density);
            }
        }
        // Ray footprint criterion for reconnecting from the previous vertex to this one (Eq. 5)
        let footprint: bool = withinFootprint(scatter, prev.rough, prev.pdf, geometry_density, threshold);
        let material: Material = surface.material;
        let n_dot_v: float = dot(surface.smooth_n, - ray.unit_direction);
        let eta: float2 = vertexEta(material, n_dot_v);
        var nee: bool = scatter && samplesLights(material);
        // Light is sampled at the top layer alone
        if (layersUsed() && (passed || layer != 0u)) {
            nee = false;
        }
#ifdef FK_FCPT_WALK
        let hair: bool = dot(surface.hair, surface.hair) > 0.0f;  // A strand's fiber: no side of it wrong, none opaque
        // Light sampled all around where flex-cuda-pt's walk samples it with no normal: off hair, translucent surfaces
        // and surfaces of one layer transmitting light, behind their face too
        let sided: bool = hair || isTranslucent(material) || (material.transmission > 0.0f && scene.layers(hit) == 1u);
#endif
        // Emission met, of the surface or a point light, weighted against light sampling at the vertex the ray left
#ifdef FK_FCPT_WALK
        var emission: float3 = material.emissive;  // On both sides, as the light sample takes it
#else
        var emission: float3 = material.emissive * max(sign(dot(- ray.unit_direction, front_n)), 0.0f);
#endif
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
        withReservoirHit(here, hit);
        let arrived: bool = replay && rc == RC_SURFACE && b == k;
        // Light sampled here once, for whichever of its three uses below the vertex takes: the replayed light sample at
        // the reconnection vertex, the forced reconnection to it, or the walk's own
        let forced: bool = b == stop && (!scatter || (rc != RC_SURFACE && rc != RC_ENV)) && rc == RC_LIGHT && !footprint
            && end_type != END_SKY;
        let replayed: bool = select(arrived, k == end && end_type == END_NEE && hit.instance_index == rc_hit.instance_index
            && hit.triangle_index == rc_hit.triangle_index && footprint, forced);
        let samples_light: bool = nee && select(replay, replayed, scatter);
        var light: TreeSample = TreeSample(float3(0.0f), float3(0.0f), 0.0f, 0u);
        var lit: float3 = float3(0.0f);
        if (samples_light) {
#ifdef FK_FCPT_WALK
            light = sampleLightTree(scene, ray.origin, AT_HAIR(float3(0.0f), surface.smooth_n), surface.geometry_n, surface.geometry_offset, sided, stream(r.seed, b + STREAM_NEE)
                , shadowContext(surface, turned, surface.geometry_n, extinction_in, filling, ray.unit_direction, b, arrivalLobe(b, prev.lobe), hit.distance, width, hit, hair)
                );
#else
            light = sampleLightTree(scene, ray.origin, AT_HAIR(float3(0.0f), surface.smooth_n), surface.geometry_n, surface.geometry_offset, AT_HAIR(true, isTranslucent(material)), stream(r.seed, b + STREAM_NEE)
                );
#endif
            lit = AT_HAIR(hairLight(scene, surface, ray.unit_direction, light, b < scene.maxBounces()), lightBSDF(ray.unit_direction, light, surface.smooth_n, surface.geometry_n, material, eta.x, eta.y, b < scene.maxBounces(), surface.random_state));
        }
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
                if (!nee || !(rgb_to_greyscale(light.radiance) > 0.0f)) {
                    return fail;
                }
                return Shift(throughput * lit / r.jac, density / r.jac);
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
                if (!(rgb_to_greyscale(light.radiance) > 0.0f)) {
                    return fail;
                }
                return Shift(throughput * lit, 1.0f);
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
#ifdef FK_FCPT_WALK
            else {
                // Seen from the camera through its medium, by what that lets through: flex-cuda-pt's walk adds it
                addGlow(sel, throughput * emission);
            }
#endif
            if (nee) {
                let f: float3 = throughput * lit;
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
            // None from hair, as flex-cuda-pt's before it samples the sky: the sky's light samples weigh by surfaces' BSDFs, not fibers'
            if (nee && AT_HAIR(false, environmentMapped(scene)) && b < scene.maxBounces()) {
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
                if (AT_HAIR(false, wrongSide(is_inside, refracted, dir, surface.geometry_n))) {
                    return fail;
                }
            } else if (!arrived) {
                var bsdf_sampled: SampleBSDF = AT_HAIR(scene.sampleHair(surface.hair, material.albedo, material.specular_tint, ray.unit_direction, surface.random_state),
                    sampleBSDF(ray.unit_direction, surface.smooth_n, material, eta.x, eta.y, surface.random_state, float2(0.0f)));
#ifdef FK_FCPT_WALK
                if (hair && !(bsdf_sampled.pdf > 0.0f)) {
                    // Hair's row past a pole: no direction
                    if (replay) {
                        return fail;
                    }
                    break;
                }
#endif
                // Rays sampled to the wrong side of the face are sampled again or mirrored, as the path tracer's
                wrong_side = AT_HAIR(false, wrongSide(is_inside, bsdf_sampled.refracted, bsdf_sampled.unit_direction, surface.geometry_n));
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
                lobe = AT_HAIR(scene.connectHair(surface.hair, material.albedo, material.specular_tint, ray.unit_direction, dir),
                    connectBSDF(ray.unit_direction, dir, surface.smooth_n, material, eta.x, eta.y, lobe_index, surface.random_state));
            }
            // Delta lobes have no competing light sample, straight transmission keeps the preceding vertex's weights
            let delta: bool = AT_HAIR(false, lobe_index != LOBE_DIFFUSE && (material.roughness == 0.0f || (lobe_index == LOBE_REFRACT && eta.x == eta.y)));
#ifdef FK_FCPT_WALK
            straight = !hair && lobe_index == LOBE_REFRACT && material.ior == 1.0f;
            // Camera status kept by a refraction at equal indices, which bends no ray (flex-cuda-pt's rule A); Cycles'
            // rule would keep it across coverage gaps alone, this one expression
            viewed = viewed && !hair && lobe_index == LOBE_REFRACT && eta.x == eta.y;
#endif
            // Translucent surfaces are thin, as in the path tracer
            let through: bool = isTranslucent(material) && lobe_index == LOBE_DIFFUSE && dot(dir, surface.geometry_n) < 0.0f;
            if (nee && !delta && !wrong_side) {
#ifdef FK_FCPT_WALK
                nee_vertex = NEEVertex(false, lobe.pdf, ray.origin, select(surface.smooth_n, float3(0.0f), sided), ray.origin + surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, through));
#else
                nee_vertex = NEEVertex(false, lobe.pdf, ray.origin, select(surface.smooth_n, float3(0.0f), isTranslucent(material)), ray.origin + surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, through));
#endif
            } else if (AT_HAIR(true, lobe_index != LOBE_REFRACT || eta.x != eta.y)) {
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
            if (layersUsed()) {
                passes = passesLayer(scene.layers(hit), lobe_index == LOBE_REFRACT, passed);
            }
            // A connection meeting another layer is not in the image of the shift
            if (layersUsed() && connect && passes) {
                return fail;
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
            // Straight transmission keeps the preceding vertex's density against the sky, as it keeps its light
            // sample: an escape past it is the direction that vertex's light sampling weighed
            sky_pdf = select(lobe.pdf, sky_pdf, lobe_index == LOBE_REFRACT && eta.x == eta.y);
#ifdef FK_FCPT_WALK
            sky_pdf = select(sky_pdf, 0.0f, hair);  // Escapes past hair, its sky unsampled, take the full weight
#endif
            if (coneUsed()) {
                spread = widened(spread, lobe.pdf, delta);
            }
            if (refracted && !through) {
                is_inside = !is_inside;
            }
            if (mediaUsed() && !(layersUsed() && passes)) {
                // Into the medium on the side it leaves by, of the face as the mesh turns it
                var faced: Surface = surface;
                faced.geometry_n = select(surface.geometry_n, - surface.geometry_n, turned);
                let sides: MediumSides = mediumSides(faced, Medium(scatter_in, extinction_in), filling, ray.unit_direction);
                let front: bool = leavesInFront(faced.geometry_n, dir, surface.geometry_n, surface.geometry_n);
                scatter_in = select(sides.behind.scatter, sides.front.scatter, front);
                extinction_in = select(sides.behind.extinction, sides.front.extinction, front);
                filling = select(sides.fillings.x, sides.fillings.y, front);
            }
            ray.unit_direction = dir;
            if (!(layersUsed() && passes)) {
#ifdef FK_FCPT_WALK
                // Straight through from the hit itself, the traversal skipping its triangle; a fiber, of no offset, from
                // its vertex past its own segment
                ray.origin += select(surface.geometry_offset, 0.0f, straight) * select(surface.smooth_n, - surface.smooth_n, is_inside != through);
#else
                ray.origin += surface.geometry_offset * select(surface.smooth_n, - surface.smooth_n, is_inside != through);
#endif
            }
        } else {
            prev.rough = false;
            // Environment next event estimation never passes texels, escapes through them take the full weight
            prev.pdf = 0.0f;
            sky_pdf = 0.0f;
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
        if (layersUsed()) {
            // Passing, the next vertex is the same hit in the other layer, reached without distance
            passed = passes;
            layer = select(0u, layer ^ 1u, passes);
            passes = false;
            if (passed) {
                // Its footprint never reconnects between layers
                prev.rough = false;
                hit.distance = 0.0f;
                continue;
            }
        }
        // Only occluders in front of the reconnection vertex matter, passing through a point light no other
        hit = scene.traverseInstanceBVH(ray, !point_light_lighting, select(POW32, distance(reconnection, ray.origin) * 1.001f, replay && b == stop && rc == RC_SURFACE),
#ifdef FK_FCPT_WALK
            !hair, straight || hair ? hit : noHit(), viewed  // A fiber's own segment skipped, from no margin
#else
            true, hit, false // Unread: FlexLight's traversal takes no skip and has no hidden surfaces
#endif
            );
        // Reaching the reconnection vertex, it is shaded exactly where the stored path has it
        if (replay && b == stop && rc == RC_SURFACE && hit.instance_index == rc_hit.instance_index && hit.triangle_index == rc_hit.triangle_index) {
            hit.uv = rc_hit.uv;
            hit.distance = distance(reconnection, ray.origin);
        }
        // The connection to the environment direction has to escape the scene
        if (replay && b == stop && rc == RC_ENV && hit.instance_index != UINT_MAX) {
            return fail;
        }
        if (mediaUsed()) {
            var ended: Shift = {};
#ifdef FK_FCPT_WALK
            let unscattered: uint = b;
#endif
            if (crossMedium(scene, r, replay, stop, rc, scale, chain, chain_throughput, is_inside, filling, b, ray,
                hit, throughput, density, weight, glowed, scatter_in, extinction_in, width, spread, prev, nee_vertex,
                sky_pdf, sel, ended)) {
                return ended;
            }
#ifdef FK_FCPT_WALK
            viewed = viewed && b == unscattered;
#endif
        }
        var arrived_end: Shift = {};
        if (arrive(scene, r, replay, stop, rc, end, end_type, scale, b, chain, chain_throughput, nee_vertex, prev,
            sky_pdf, density, hit, filling, scatter_in, extinction_in, weight, glowed, spread, ray, throughput, width,
            sel, arrived_end)) {
            return arrived_end;
        }
    }
    return fail;
}
#endif

#ifdef FK_RESTIR_PASSES
// Target plumbing: WGSL's select of int2s, in its argument order f, t, cond, by a condition or per component
[ForceInline] int2 select(int2 f, int2 t, bool cond) { return select(cond, t, f); }
[ForceInline] int2 select(int2 f, int2 t, bool2 cond) { return select(cond, t, f); }

func project<S: IScene>(scene: S, view: float3x3, camera: float3, position: float3) -> float2 {
    let clip_space: float3 = mul(position - camera, view);
    let screen_space: float2 = (clip_space.xy / clip_space.z) * 0.5f + 0.5f;
    return float2(screen_space.x, 1.0f - screen_space.y) * float2(scene.renderSize());
}

func previousValid<S: IScene>(scene: S, q: int2) -> bool {
    return all(q >= int2(0)) && all(q < int2(scene.renderSize())) && asfloat(scene.reservoirPrevious(q, 0u).w) > 0.0f;
}

// Backprojection of the camera motion, or the dual motion vector of the surface previously seen there (Sec. 6.4)
public func temporalNeighbor<S: IScene>(scene: S, p: int2, dom: Domain) -> int2 {
    // Primary hits are rasterized at pixel centers
    let q: int2 = int2(floor(project(scene, scene.prevViewMatrix(), scene.prevCameraPosition(), dom.x1)));
    if (!previousValid(scene, q)) {
        return int2(-1);
    }
    let previous: Domain = scene.previousDomain(q);
    if (previous.hit.instance_index == dom.hit.instance_index && distance(previous.x1, dom.x1) <= dom.hit.distance * 8.0f / float(scene.renderSize().x)) {
        return q;
    }
    let dual: int2 = int2(floor(float2(p + q) + 1.0f - project(scene, scene.viewMatrix(), scene.cameraPosition(), previous.x1)));
    return select(int2(-1), dual, previousValid(scene, dual));
}

// Partner of p in reuse texture t, randomly flipped, transposed and offset every frame (Sec. 3.2)
public func partner<S: IScene>(scene: S, p: int2, t: uint) -> int2 {
    var sizes: int[3] = { 254, 230, 210 };
    let size: int = sizes[t];
    let random: uint = hash(scene.frame() * 3u + t);
    let flip: int2 = select(int2(1), int2(-1), bool2((random & 1u) != 0u, (random & 2u) != 0u));
    let transpose: bool = (random & 4u) != 0u;
    let offset: int2 = int2(int((random >> 8u) & 255u), int((random >> 16u) & 255u));
    let texel: int2 = ((select(p, p.yx, transpose) * flip + offset) % size + size) % size;
    let delta: int2 = scene.pairing(texel, t).xy * flip;
    return p + select(delta, delta.yx, transpose);
}

#endif

#ifdef FK_RESTIR
public func shift<S: IScene>(scene: S, dom: Domain, r: Reservoir) -> Shift {
    var sel: Selection = emptySelection();
    if (r.w <= 0.0f) {
        return Shift(float3(0.0f), 0.0f);
    }
    return walk(scene, dom, r, true, 0.0f, sel);
}

// Shifting into an identical domain is the identity
public func sameDomain(a: Domain, b: Domain) -> bool {
    return all(a.x0 == b.x0) && a.hit.instance_index == b.hit.instance_index && a.hit.triangle_index == b.hit.triangle_index && all(a.hit.uv == b.hit.uv);
}
#endif

#ifdef FK_RESTIR_PASSES
__extern_cpp public struct ShiftJob {
    __extern_cpp public Domain dom;
    __extern_cpp public Reservoir r;
}

// Temporal round job t of p: the previous frame's sample into the current domain (t = 0) or the current sample into the
// previous domain (t = 1). False if the shift is zero or the identity, which temporal reuse handles itself.
public func temporalJob<S: IScene>(scene: S, p: int2, t: uint, inout job: ShiftJob) -> bool {
    var dom: Domain = {};
    if (t > 1u || !scene.storedDomainInitial(p, dom)) {
        return false;
    }
    let q: int2 = temporalNeighbor(scene, p, dom);
    if (q.x < 0) {
        return false;
    }
    if (t == 0u) {
        job = ShiftJob(dom, scene.loadReservoirPrevious(q));
    } else {
        job = ShiftJob(scene.previousDomain(q), scene.loadReservoirInitial(p));
    }
    return job.r.w > 0.0f && (t == 0u || !sameDomain(job.dom, dom));
}

// Spatial round job t of p: its sample into the domain of partner t
public func spatialJob<S: IScene>(scene: S, p: int2, t: uint, inout job: ShiftJob) -> bool {
    if (t > 2u || any(p >= int2(scene.renderSize()))) {
        return false;
    }
    job.r = scene.loadReservoirTemporal(p);
    return job.r.w > 0.0f && scene.storedDomainTemporal(partner(scene, p, t), job.dom);
}

// Compaction bin of shifting r: reconnection type, with environment next event estimation apart from light sampling, and replay depth
public func shiftBin(r: Reservoir) -> uint {
    let rc: uint = extractBits(r.path, PATH_RC, 2u);
    let kind: uint = select(rc, 4u, rc == RC_LIGHT && extractBits(r.path, PATH_TYPE, 3u) == END_SKY);
    let depth: uint = select(extractBits(r.path, PATH_K, 5u), extractBits(r.path, PATH_END, 5u) + 1u, rc == RC_NONE);
    return kind * SHIFT_DEPTHS + clamp(depth, 1u, SHIFT_DEPTHS) - 1u;
}

// Bins of the jobs of p, SHIFT_BINS for shifts without work
public func temporalBins<S: IScene>(scene: S, p: int2) -> uint[3] {
    var bins: uint[3] = { SHIFT_BINS, SHIFT_BINS, SHIFT_BINS };
    for (var t: uint = 0u; t < 2u; t++) {
        var job: ShiftJob = {};
        if (temporalJob(scene, p, t, job)) {
            bins[t] = shiftBin(job.r);
        }
    }
    return bins;
}

public func spatialBins<S: IScene>(scene: S, p: int2) -> uint[3] {
    var bins: uint[3] = { SHIFT_BINS, SHIFT_BINS, SHIFT_BINS };
    for (var t: uint = 0u; t < scene.restirNeighbours(); t++) {
        var job: ShiftJob = {};
        if (spatialJob(scene, p, t, job)) {
            bins[t] = shiftBin(job.r);
        }
    }
    return bins;
}
#endif

#ifdef FK_RESTIR_PASSES
groupshared Atomic<uint> bin_jobs[SHIFT_BINS];
groupshared uint bin_offsets[SHIFT_BINS];

// Target plumbing: workgroup memory starts at zero in WGSL alone, Vulkan's is zeroed first, by the bins' invocations
[ForceInline] void zeroBins(uint local_invocation_index) {
    __target_switch {
    case spirv:
        if (local_invocation_index < SHIFT_BINS) {
            bin_jobs[local_invocation_index].store(0u);
        }
        GroupMemoryBarrierWithGroupSync();
    default:
        return;
    }
}

// Count the jobs of the workgroup per bin
public func countShifts<S: IScene>(scene: S, bins: uint[3], local_invocation_index: uint) {
    __target_switch {
    case cuda:
        // Target plumbing: flex-cuda-pt's raygens share no memory, each invocation counts its own jobs
        for (var t: uint = 0u; t < 3u; t++) {
            if (bins[t] < SHIFT_BINS) {
                scene.queueCountAdd(bins[t], 1u);
            }
        }
    default:
        zeroBins(local_invocation_index);
        for (var t: uint = 0u; t < 3u; t++) {
            if (bins[t] < SHIFT_BINS) {
                bin_jobs[bins[t]].add(1u);
            }
        }
        GroupMemoryBarrierWithGroupSync();
        if (local_invocation_index < SHIFT_BINS) {
            let jobs: uint = bin_jobs[local_invocation_index].load();
            if (jobs > 0u) {
                scene.queueCountAdd(local_invocation_index, jobs);
            }
        }
    }
}

// Write the jobs of the workgroup bin by bin into the queue and the size of the indirect dispatch running them
public func queueShifts<S: IScene>(scene: S, p: int2, bins: uint[3], global_invocation_id: uint3, local_invocation_index: uint) {
    __target_switch {
    case cuda:
        // Target plumbing: flex-cuda-pt's raygens share no memory, each invocation places its own jobs after the bins before theirs
        for (var t: uint = 0u; t < 3u; t++) {
            if (bins[t] < SHIFT_BINS) {
                var start: uint = 0u;
                for (var bin: uint = 0u; bin < bins[t]; bin++) {
                    start += scene.queueCountLoad(bin);
                }
                scene.queueJobStore(start + scene.queueCursorAdd(bins[t], 1u), uint(p.x) | (uint(p.y) << 14u) | (t << 28u));
            }
        }
    default:
        zeroBins(local_invocation_index);
        var slots: uint[3] = {};
        for (var t: uint = 0u; t < 3u; t++) {
            if (bins[t] < SHIFT_BINS) {
                slots[t] = bin_jobs[bins[t]].add(1u);
            }
        }
        GroupMemoryBarrierWithGroupSync();
        if (local_invocation_index < SHIFT_BINS) {
            let jobs: uint = bin_jobs[local_invocation_index].load();
            if (jobs > 0u) {
                var start: uint = 0u;
                for (var bin: uint = 0u; bin < local_invocation_index; bin++) {
                    start += scene.queueCountLoad(bin);
                }
                bin_offsets[local_invocation_index] = start + scene.queueCursorAdd(local_invocation_index, jobs);
            }
        }
        GroupMemoryBarrierWithGroupSync();
        for (var t: uint = 0u; t < 3u; t++) {
            if (bins[t] < SHIFT_BINS) {
                scene.queueJobStore(bin_offsets[bins[t]] + slots[t], uint(p.x) | (uint(p.y) << 14u) | (t << 28u));
            }
        }
    }
    if (all(global_invocation_id.xy == uint2(0u))) {
        var groups: uint = 0u;
        for (var bin: uint = 0u; bin < SHIFT_BINS; bin++) {
            groups += (scene.queueCountLoad(bin) + 63u) / 64u;
        }
        scene.queueDispatchStore(min(groups, 65535u), (groups + 65534u) / 65535u, 1u);
    }
}

// Queued job of an invocation of the indirect shift passes, UINT_MAX for none. Every workgroup works on a single bin.
public func queuedShift<S: IScene>(scene: S, workgroup_id: uint3, local_invocation_index: uint) -> uint {
    var group: uint = workgroup_id.y * 65535u + workgroup_id.x;
    var start: uint = 0u;
    for (var bin: uint = 0u; bin < SHIFT_BINS; bin++) {
        let jobs: uint = scene.queuedShifts(3u + bin);
        let groups: uint = (jobs + 63u) / 64u;
        if (group < groups) {
            let index: uint = group * 64u + local_invocation_index;
            if (index < jobs) {
                return scene.queuedShifts(3u + 2u * SHIFT_BINS + start + index);
            }
            return UINT_MAX;
        }
        group -= groups;
        start += jobs;
    }
    return UINT_MAX;
}
#endif

#ifdef FK_RESTIR_PASSES
// Initial candidates
public func restir_initial<S: IScene>(scene: S, global_invocation_id: uint3) {
    let p: int2 = int2(global_invocation_id.xy);
    var dom: Domain = {};
    if (!scene.currentDomain(p, dom)) {
        scene.storeReservoirInitial(p, Reservoir(), dom.hit);
        return;
    }
    let pixel_seed: uint = stream(hash(scene.frame()), global_invocation_id.x + scene.renderSize().x * global_invocation_id.y);
    var initial: Selection = {};
    initial.random_state = stream(pixel_seed, STREAM_SELECT);
    for (var i: uint = 0u; i < scene.samples(); i++) {
        var r: Reservoir = {};
        r.seed = stream(pixel_seed, i);
        walk(scene, dom, r, false, 1.0f / float(scene.samples()), initial);
    }
    scene.storeReservoirInitial(p, finalize(initial, 1.0f), dom.hit);
}

// Temporal reuse with the shifts of the temporal round
public func restir_temporal<S: IScene>(scene: S, global_invocation_id: uint3) {
    let p: int2 = int2(global_invocation_id.xy);
    var dom: Domain = {};
    if (!scene.currentDomain(p, dom)) {
        scene.storeReservoirTemporal(p, Reservoir(), dom.hit);
        return;
    }
    var r: Reservoir = scene.loadReservoirInitial(p);
    let q: int2 = temporalNeighbor(scene, p, dom);
    if (q.x >= 0) {
        let temporal: Reservoir = scene.loadReservoirPrevious(q);
        // Optionally lower the confidence cap where the previous frame duplicated samples (Sec. 5), this biases the estimate
        let duplicated: float = select(0.0f, asfloat(scene.duplication(q).x), scene.restirDecorrelation() == 1u);
        let c_t: float = min(temporal.c, confidenceCap(duplicated));
        let to_current: float4 = asfloat(scene.temporalShift(p, 0u));
        var to_previous: float4 = float4(r.f, 1.0f);
        if (!sameDomain(scene.previousDomain(q), dom)) {
            to_previous = asfloat(scene.temporalShift(p, 1u));
        }
        let p_c: float = rgb_to_greyscale(r.f);
        let p_t: float = rgb_to_greyscale(temporal.f);
        var sel: Selection = {};
        sel.random_state = stream(stream(hash(scene.frame()), global_invocation_id.x + scene.renderSize().x * global_invocation_id.y), STREAM_SELECT + 1u);
        let weights: float2 = temporalWeights(r.c, p_c, c_t, p_t, rgb_to_greyscale(to_previous.xyz), rgb_to_greyscale(to_current.xyz));
        offerShifted(sel, r, Shift(r.f, 1.0f), weights.x);
        offerShifted(sel, temporal, Shift(to_current.xyz, to_current.w), weights.y);
        r = finalize(sel, r.c + c_t);
    }
    scene.storeReservoirTemporal(p, r, dom.hit);
}
#endif

#ifdef FK_RESTIR_PASSES
// The temporal round of the shift queue
public func restir_temporal_count<S: IScene>(scene: S, global_invocation_id: uint3, local_invocation_index: uint) {
    countShifts(scene, temporalBins(scene, int2(global_invocation_id.xy)), local_invocation_index);
}

public func restir_temporal_prepass<S: IScene>(scene: S, global_invocation_id: uint3, local_invocation_index: uint) {
    let p: int2 = int2(global_invocation_id.xy);
    let bins: uint[3] = temporalBins(scene, p);
    for (var t: uint = 0u; t < 2u; t++) {
        if (bins[t] == SHIFT_BINS) {
            scene.storeTemporalShift(p, t, uint4(0u));
        }
    }
    queueShifts(scene, p, bins, global_invocation_id, local_invocation_index);
}

public func restir_temporal_shift<S: IScene>(scene: S, workgroup_id: uint3, local_invocation_index: uint) {
    let job: uint = queuedShift(scene, workgroup_id, local_invocation_index);
    if (job != UINT_MAX) {
        let p: int2 = int2(uint2(job, job >> 14u) & uint2(16383u));
        var shift_job: ShiftJob = {};
        temporalJob(scene, p, job >> 28u, shift_job);
        let shifted: Shift = shift(scene, shift_job.dom, shift_job.r);
        scene.storeTemporalShift(p, job >> 28u, uint4(asuint(shifted.f), asuint(shifted.jac)));
    }
}

// The spatial round of the shift queue, every pixel's sample to its partners of all reuse textures
public func restir_count<S: IScene>(scene: S, global_invocation_id: uint3, local_invocation_index: uint) {
    countShifts(scene, spatialBins(scene, int2(global_invocation_id.xy)), local_invocation_index);
}

public func restir_prepass<S: IScene>(scene: S, global_invocation_id: uint3, local_invocation_index: uint) {
    let p: int2 = int2(global_invocation_id.xy);
    let bins: uint[3] = spatialBins(scene, p);
    for (var t: uint = 0u; t < 3u; t++) {
        if (bins[t] == SHIFT_BINS) {
            scene.storeShiftData(p, t, uint4(0u));
        }
    }
    queueShifts(scene, p, bins, global_invocation_id, local_invocation_index);
}

public func restir_shift<S: IScene>(scene: S, workgroup_id: uint3, local_invocation_index: uint) {
    let job: uint = queuedShift(scene, workgroup_id, local_invocation_index);
    if (job != UINT_MAX) {
        let p: int2 = int2(uint2(job, job >> 14u) & uint2(16383u));
        var shift_job: ShiftJob = {};
        spatialJob(scene, p, job >> 28u, shift_job);
        let shifted: Shift = shift(scene, shift_job.dom, shift_job.r);
        scene.storeShiftData(p, job >> 28u, uint4(asuint(shifted.f), asuint(shifted.jac)));
    }
}
#endif

#ifdef FK_RESTIR_PASSES
// Paired spatial reuse with pairwise MIS (Sec. 3) and shading with vector-valued weights (Sec. 6.3)
public func restir_spatial<S: IScene>(scene: S, global_invocation_id: uint3) {
    let p: int2 = int2(global_invocation_id.xy);
    var dom: Domain = {};
    if (!scene.currentDomain(p, dom)) {
        scene.storeReservoirPrevious(p, Reservoir(), dom.hit);
        let screen_space: float2 = float2(global_invocation_id.xy) / float2(scene.renderSize().xy) * float2(2.0f, -2.0f) + float2(-1.0f, 1.0f);
        // If there is no triangle render ambient color
        scene.storeColor(p, 0u, float4(environment(scene, normalize(mul(float3(screen_space, 1.0f), scene.invViewMatrix()))), 1.0f));
        if (scene.isTemporal() == 1u) {
            scene.storeColor(p, 1u, float4(0.0f));
        }
        return;
    }
    let r: Reservoir = scene.loadReservoirTemporal(p);
    var count: float = 0.0f;
    var c_sum: float = r.c;
    for (var t: uint = 0u; t < scene.restirNeighbours(); t++) {
        let q: int2 = partner(scene, p, t);
        var neighbor: Domain = {};
        if (scene.currentDomain(q, neighbor)) {
            count += 1.0f;
            c_sum += asfloat(scene.reservoirTemporal(q, 0u).w);
        }
    }
    // Confidence of the current pixel is split evenly across the pairs
    let c_pair: float = r.c / max(count, 1.0f);
    let p_c: float = rgb_to_greyscale(r.f);
    var canonical_mis: float = select(0.0f, 1.0f, count == 0.0f);
    var sel: Selection = {};
    sel.random_state = stream(stream(hash(scene.frame()), global_invocation_id.x + scene.renderSize().x * global_invocation_id.y), STREAM_SELECT + 2u);
    for (var t: uint = 0u; t < scene.restirNeighbours(); t++) {
        let q: int2 = partner(scene, p, t);
        var neighbor_dom: Domain = {};
        if (scene.currentDomain(q, neighbor_dom)) {
            let neighbor: Reservoir = scene.loadReservoirTemporal(q);
            let to_here: float4 = asfloat(scene.shiftData(q, t));
            let to_there: float4 = asfloat(scene.shiftData(p, t));
            let share: float = pairShare(neighbor.c, c_pair, c_sum);
            if (p_c > 0.0f) {
                canonical_mis += canonicalWeight(share, c_pair, p_c, neighbor.c, rgb_to_greyscale(to_there.xyz));
            }
            offerShifted(sel, neighbor, Shift(to_here.xyz, to_here.w), neighborWeight(share, neighbor.c, rgb_to_greyscale(neighbor.f), c_pair, rgb_to_greyscale(to_here.xyz)));
        }
    }
    offerShifted(sel, r, Shift(r.f, 1.0f), canonical_mis);
    scene.storeReservoirPrevious(p, finalize(sel, c_sum), dom.hit);
    scene.storePreviousLayer(p, 5u, uint4(asuint(dom.hit.uv), 0u, 0u));
    let primary: Surface = scene.surfaceAt(dom.hit, dom.x1, sel.random_state);
#ifdef FK_FCPT_WALK
    // flex-cuda-pt's walk adds the primary hit's emission itself, through the camera's medium
    let emission: float3 = float3(0.0f);
#else
    let emission: float3 = select(primary.material.emissive * max(sign(dot(normalize(dom.x0 - dom.x1), primary.smooth_n)), 0.0f), float3(0.0f), primary.skip);
#endif
    // Clamp color to 16 bit float
    let final_color: float3 = clamp(sel.color + emission, float3(0.0f), float3(65519.0f));
    scene.storeColor(p, 0u, float4(final_color, 1.0f));
    if (scene.isTemporal() == 1u) {
        scene.storeColor(p, 1u, float4(dom.x1, float(dom.hit.instance_index)));
    }
}
#endif

#ifdef FK_RESTIR_PASSES
groupshared uint duplication_seeds[576];

// Target plumbing: the seed of the sample last frame's reservoir at q holds, zero for none or outside the image, as
// restir_duplicates reads it into its workgroup's tile
uint previousSeed<S: IScene>(S scene, int2 q) {
    var seed: uint = 0u;
    if (all(q >= int2(0)) && all(q < int2(scene.renderSize()))) {
        let l0: uint4 = scene.reservoirPrevious(q, 0u);
        seed = select(0u, l0.x, asfloat(l0.z) > 0.0f);
    }
    return seed;
}

// Fraction of the 17 x 17 neighborhood sharing each pixel's sample (Sec. 5)
public func restir_duplicates<S: IScene>(scene: S, global_invocation_id: uint3, local_invocation_id: uint3, local_invocation_index: uint) {
    __target_switch {
    case cuda:
        // Target plumbing: flex-cuda-pt's raygens share no memory, each invocation reads its neighborhood's seeds itself
        let own: uint = previousSeed(scene, int2(global_invocation_id.xy));
        var count: uint = 0u;
        for (var y: int = -8; y <= 8; y++) {
            for (var x: int = -8; x <= 8; x++) {
                count += select(0u, 1u, previousSeed(scene, int2(global_invocation_id.xy) + int2(x, y)) == own);
            }
        }
        let score: float = select(0.0f, float(count - 1u) / 288.0f, own != 0u);
        scene.storeDuplication(int2(global_invocation_id.xy), uint4(asuint(score), 0u, 0u, 0u));
    default:
        let corner: int2 = int2(global_invocation_id.xy - local_invocation_id.xy) - 8;
        for (var i: uint = local_invocation_index; i < 576u; i += 64u) {
            let q: int2 = corner + int2(int(i % 24u), int(i / 24u));
            var seed: uint = 0u;
            if (all(q >= int2(0)) && all(q < int2(scene.renderSize()))) {
                let l0: uint4 = scene.reservoirPrevious(q, 0u);
                seed = select(0u, l0.x, asfloat(l0.z) > 0.0f);
            }
            duplication_seeds[i] = seed;
        }
        GroupMemoryBarrierWithGroupSync();
        let own: uint = duplication_seeds[(local_invocation_id.y + 8u) * 24u + local_invocation_id.x + 8u];
        var count: uint = 0u;
        for (var y: uint = 0u; y < 17u; y++) {
            for (var x: uint = 0u; x < 17u; x++) {
                count += select(0u, 1u, duplication_seeds[(local_invocation_id.y + y) * 24u + local_invocation_id.x + x] == own);
            }
        }
        let score: float = select(0.0f, float(count - 1u) / 288.0f, own != 0u);
        scene.storeDuplication(int2(global_invocation_id.xy), uint4(asuint(score), 0u, 0u, 0u));
    }
}
#endif

#ifdef FK_RESTIR
// The passes over the consumer's scene of the ReSTIR variant outputs, which its compute entry points and raygens call
// with their builtins, and the walk and shift for its own loops
[CudaDeviceExport] public func walk_hook(dom: Domain, r: Reservoir, replay: bool, scale: float, inout sel: Selection) -> Shift {
    HookScene scene;
    return walk(scene, dom, r, replay, scale, sel);
}
[CudaDeviceExport] public func shift_hook(dom: Domain, r: Reservoir) -> Shift { HookScene scene; return shift(scene, dom, r); }
#ifdef FK_RESTIR_PASSES
[CudaDeviceExport] public func restir_initial_hook(global_invocation_id: uint3) { HookScene scene; restir_initial(scene, global_invocation_id); }
[CudaDeviceExport] public func restir_temporal_hook(global_invocation_id: uint3) { HookScene scene; restir_temporal(scene, global_invocation_id); }
[CudaDeviceExport] public func restir_temporal_count_hook(global_invocation_id: uint3, local_invocation_index: uint) {
    HookScene scene;
    restir_temporal_count(scene, global_invocation_id, local_invocation_index);
}
[CudaDeviceExport] public func restir_temporal_prepass_hook(global_invocation_id: uint3, local_invocation_index: uint) {
    HookScene scene;
    restir_temporal_prepass(scene, global_invocation_id, local_invocation_index);
}
[CudaDeviceExport] public func restir_temporal_shift_hook(workgroup_id: uint3, local_invocation_index: uint) {
    HookScene scene;
    restir_temporal_shift(scene, workgroup_id, local_invocation_index);
}
[CudaDeviceExport] public func restir_count_hook(global_invocation_id: uint3, local_invocation_index: uint) {
    HookScene scene;
    restir_count(scene, global_invocation_id, local_invocation_index);
}
[CudaDeviceExport] public func restir_prepass_hook(global_invocation_id: uint3, local_invocation_index: uint) {
    HookScene scene;
    restir_prepass(scene, global_invocation_id, local_invocation_index);
}
[CudaDeviceExport] public func restir_shift_hook(workgroup_id: uint3, local_invocation_index: uint) {
    HookScene scene;
    restir_shift(scene, workgroup_id, local_invocation_index);
}
[CudaDeviceExport] public func restir_spatial_hook(global_invocation_id: uint3) { HookScene scene; restir_spatial(scene, global_invocation_id); }
[CudaDeviceExport] public func restir_duplicates_hook(global_invocation_id: uint3, local_invocation_id: uint3, local_invocation_index: uint) {
    HookScene scene;
    restir_duplicates(scene, global_invocation_id, local_invocation_id, local_invocation_index);
}
#endif
#endif
