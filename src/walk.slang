implementing pathtracer;

// Bit offsets of the packed path description
public static const uint PATH_END = 0u;
public static const uint PATH_TYPE = 12u;

// Single-vertex roughness threshold (Sec. 4.2)
static const float RESTIR_ROUGHNESS = 0.2;
// Dual ray footprint constant c / 100 * 4 PI of Eq. 5 with c = 0.02
static const float RESTIR_FOOTPRINT = 0.0025132741228718345;
// Temporal confidence cap and its duplication-driven reduction (Sec. 5)
static const float RESTIR_CAP = 20.0;
static const float RESTIR_CAP_MIN = 1.0;
static const float RESTIR_DUPLICATION_ALPHA = 0.1;

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

// Bounds, normal cone (w, cos_theta_o) and power phi of a node's emitters
__target_intrinsic(cuda, "LightNode")
__extern_cpp public struct LightBounds {
    __extern_cpp public float3 low;
    __extern_cpp public float3 high;
    __extern_cpp public float3 w;
    __extern_cpp public float phi;
    __extern_cpp public float cos_theta_o;
};

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


// Sign turning the normals toward the arriving ray, kept for transmitting surfaces
[CudaDeviceExport] public func facingSign(transmission: float, face: float3, direction: float3) -> float {
    return transmission > 0.0f || dot(face, direction) < 0.0f ? 1.0f : -1.0f;
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

float interpolate(float a, float b, float t) {
    __target_switch {
    case wgsl: __intrinsic_asm "mix($0, $1, $2)";
    default: return a + (b - a) * t;
    }
}


// cos(max(0, a - b)) = cos_a * cos_b + sin_a * sin_b, 1 for a < b
[CudaDeviceExport] public func cosSubClamped(sin_a: float, cos_a: float, sin_b: float, cos_b: float) -> float {
    return select(cos_a * cos_b + sin_a * sin_b, 1.0f, cos_a > cos_b);
}
// sin = sqrt(1 - cos^2) on [0, PI]
[CudaDeviceExport] public func sine(c: float) -> float {
    return sqrt(max(1.0f - c * c, 0.0f));
}

// Importance of a node to p
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
    let sin_theta_x: float = select(sine(cos_theta_w) * node.cos_theta_o - cos_theta_w * sin_theta_o, 0.0f, cos_theta_w > node.cos_theta_o);
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

// One step down the light tree by the children's importance, pick rescaled
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

// Probability of one step down to child
[CudaDeviceExport] public func childShare(first: LightBounds, second: LightBounds, p: float3, normal: float3, child: uint) -> float {
    let shares: float2 = float2(importance(first, p, normal), importance(second, p, normal));
    return select(0.0f, shares[child] / (shares.x + shares.y), shares[child] > 0.0f);
}

// w = a^2 / (a^2 + b^2) = 1 / (1 + (b / a)^2), the power heuristic
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

// Uniform direction in the cone toward the sphere by solid angle
[CudaDeviceExport] public func sampleSphere(center: float3, radius: float, p: float3, u1: float, u2: float) -> float3 {
    let sin2: float = radius * radius / dot(center - p, center - p);
    // 1 - cos_theta = u1 * (1 - cos_theta_max) = u1 * sin^2 / (1 + cos_theta_max), 2 * u1 inside
    let one_minus_cos: float = select(u1 * sin2 / (1.0f + sqrt(max(1.0f - sin2, 0.0f))), 2.0f * u1, sin2 >= 1.0f);
    let sin_theta: float = sqrt(max(one_minus_cos * (2.0f - one_minus_cos), 0.0f));
    let phi: float = 2.0f * PI * u2;
    return tangentToWorld(float3(sin_theta * cos(phi), 1.0f - one_minus_cos, sin_theta * sin(phi)), normalize(center - p));
}
