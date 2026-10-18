// Target plumbing: Slang's syntax for FlexLight's WGSL, besides what is marked where it is: a module of public
// declarations, fn reads func, const static const, structs and their members carry __extern_cpp public, f32, u32,
// vec2<f32>, vec3<f32>, vec4<u32> and mat3x3<f32> read float, uint, float2, float3, uint4 and float3x3, ptr<function, T>
// parameters inout T, whose *x and &x read x, and mat3x3<f32>(t, b, n) of columns and tbn * v read float3x3(t, b, n)
// and mul(v, tbn), as Slang keeps matrices by rows
module pathtracer;

public static const float PI = 3.141592653589793;
public static const float MAX_SAFE_INTEGER_FOR_F32 = 8388607.0;
public static const uint UINT_MAX = 4294967295u;
public static const float BIAS = 0.0000152587890625;
// const BIAS: f32 = 0.0000009536743164;
public static const float INV_PI = 0.3183098861837907;

// Target plumbing: the WGSL builtins the shared code calls, lowered to what each consumer calls in their place: CUDA's
// intrinsics in flex-cuda-pt, for C++ the formulas of their host shims in tests/shim, which made the CUDA goldens;
// WGSL takes its own builtin back, as the name is taken here
public float3 normalize(float3 a) {
    __target_switch {
    case cuda: __intrinsic_asm "(($0) * make_float3(rnorm3df(($0).x, ($0).y, ($0).z)))";
    case wgsl: __intrinsic_asm "normalize($0)";
    default: return a * (1.0f / sqrt(dot(a, a)));
    }
}
// Target plumbing: WGSL's inverseSqrt, lowered as normalize above
public float inverseSqrt(float x) {
    __target_switch {
    case cuda: __intrinsic_asm "rsqrtf($0)";
    case wgsl: __intrinsic_asm "inverseSqrt($0)";
    default: return 1.0f / sqrt(x);
    }
}
// Target plumbing: WGSL's select, in its argument order f, t, cond
[ForceInline] public float select(float f, float t, bool cond) { return select(cond, t, f); }
[ForceInline] public float3 select(float3 f, float3 t, bool cond) { return select(cond, t, f); }
[ForceInline] public float3 select(float3 f, float3 t, bool3 cond) { return select(cond, t, f); }
// Target plumbing: x as is, but an expression Slang can't equate with an equal one before it, which it would reuse
// where the WGSL repeats it, and GPU drivers then fuse the multiply-adds around it otherwise
public float unshared(float x) {
    __target_switch {
    case wgsl: __intrinsic_asm "$0";
    default: return x;
    }
}
// Target plumbing: WGSL's - of a vector, which Slang writes 0 - x, positive where x is zero and so -x negative
public float3 negate(float3 x) {
    __target_switch {
    case wgsl: __intrinsic_asm "(-$0)";
    default: return -x;
    }
}
// Target plumbing: WGSL's mix, sign and insertBits, lowered as normalize above, elsewhere by their WGSL definitions
public float3 mix(float3 e1, float3 e2, float e3) {
    __target_switch {
    case wgsl: __intrinsic_asm "mix($0, $1, $2)";
    default: return e1 * (1.0f - e3) + e2 * e3;
    }
}
public float sign(float e) {
    __target_switch {
    case wgsl: __intrinsic_asm "sign($0)";
    default: return e > 0.0f ? 1.0f : e < 0.0f ? -1.0f : 0.0f;
    }
}
public uint insertBits(uint e, uint newbits, uint offset, uint count) {
    __target_switch {
    case wgsl: __intrinsic_asm "insertBits($0, $1, $2, $3)";
    default: return (e & ~(((1u << count) - 1u) << offset)) | ((newbits & ((1u << count) - 1u)) << offset);
    }
}

// Target plumbing: FlexLight's own Material (pathtracer-compute.wgsl, rasterizer-compute.wgsl), laid out by its upload,
// and flex-cuda-pt's BSDFMaterial (renderer.h) of the same fields; the struct for C++
__target_intrinsic(wgsl, "Material")
__target_intrinsic(cuda, "BSDFMaterial")
__extern_cpp public struct Material {
    __extern_cpp public float3 albedo;
    __extern_cpp public float3 emissive;
    __extern_cpp public float roughness;
    __extern_cpp public float metallic;
    __extern_cpp public float transmission;
    __extern_cpp public float ior;
};

__extern_cpp public struct Random {
    __extern_cpp public uint state;
    __extern_cpp public float value;
};

__extern_cpp public struct RandomSphere {
    __extern_cpp public uint state;
    __extern_cpp public float3 value;
};

__extern_cpp public struct RandomHemisphere {
    __extern_cpp public uint state;
    __extern_cpp public float3 value;
};

[CudaDeviceExport] public func rgb_to_greyscale(rgb: float3) -> float {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

// Target plumbing: flex-cuda-pt's generator for every target but WGSL, as renderer.cu defines it
float random(inout uint state) { return ((state = hash(state)) >> 8) * 0x1p-24f; }

// Target plumbing: declared as in C, as random advances state in place, which func's parameters don't allow
[CudaDeviceExport] public Random pcg(uint state) {
    // Target plumbing: FlexLight's generator for WGSL, flex-cuda-pt's for every other target
    __target_switch {
    case wgsl:
    // PCG random number generator
    // Reference: http://www.pcg-random.org/
    var new_state: uint = state * 747796405u + 2891336453u;
    let word: uint = ((new_state >> ((new_state >> 28u) + 4u)) ^ new_state) * 277803737u;
    let result: uint = (word >> 22u) ^ word;
    // Return random f32 between 0 and 1
    let random: float = float(result) / float(UINT_MAX);
    return Random(new_state, random);
    default:
        const float value = random(state);
        return Random(state, value);
    }
}

[CudaDeviceExport] public func normal_distribution(state: uint) -> Random {
    let r1: Random = pcg(state);
    let r2: Random = pcg(r1.state);
    // Sample normal distribution
    let theta: float = 2.0f * PI * r1.value;
    let rho: float = sqrt(-2.0f * clamp(log(r2.value), - MAX_SAFE_INTEGER_FOR_F32, 0.0f));
    return Random(r2.state, rho * cos(theta));
}

[CudaDeviceExport] public func random_sphere(state: uint) -> RandomSphere {
    let x: Random = normal_distribution(state);
    let y: Random = normal_distribution(x.state);
    let z: Random = normal_distribution(y.state);
    return RandomSphere(z.state, normalize(float3(x.value, y.value, z.value)));
}

[CudaDeviceExport] public func random_hemisphere(state: uint, normal: float3) -> RandomHemisphere {
    let random_sphere: RandomSphere = random_sphere(state);
    // If the random sphere is in the same hemisphere as the normal, return it
    if(dot(random_sphere.value, normal) > 0.0f) {
        return RandomHemisphere(random_sphere.state, random_sphere.value);
    } else {
        // Otherwise, return the opposite direction
        // Target plumbing: negate(x) for - x, see negate
        return RandomHemisphere(random_sphere.state, negate(random_sphere.value));
    }
}

[CudaDeviceExport] public func trowbridgeReitz(alpha: float, n_dot_h: float) -> float {
    let numerator: float = alpha * alpha;
    let denom: float = n_dot_h * n_dot_h * (numerator - 1.0f) + 1.0f;
    return numerator / max(PI * denom * denom, BIAS);
}

[CudaDeviceExport] public func G1(alpha: float, n_dot_x: float) -> float {
    let k: float = alpha * 0.5f;
    return n_dot_x / max(n_dot_x * (1.0f - k) + k, BIAS);
}

// Exact Smith masking of GGX, the visible normal density sampleGGXVNDF draws from
[CudaDeviceExport] public func smithG1(alpha: float, n_dot_x: float) -> float {
    let alpha_sq: float = alpha * alpha;
    return 2.0f * n_dot_x / (n_dot_x + sqrt(alpha_sq + (1.0f - alpha_sq) * n_dot_x * n_dot_x));
}

[CudaDeviceExport] public func fresnel(cos_theta: float, eta_i: float, eta_o: float) -> float {
    // Compute sini using Snell's law
    let sin_theta = sqrt(max(0.0f, 1.0f - cos_theta * cos_theta));
    let sin_psi = (eta_i / eta_o) * sin_theta;
    // Total internal reflection
    var kr: float = 1.0f;
    if (sin_psi < 1.0f) {
        let cos_psi = sqrt(max(0.0f, 1.0f - sin_psi * sin_psi));
        // cos = abs(cosi);
        let Rs = ((eta_o * cos_theta) - (eta_i * cos_psi)) / ((eta_o * cos_theta) + (eta_i * cos_psi));
        let Rp = ((eta_i * cos_theta) - (eta_o * cos_psi)) / ((eta_i * cos_theta) + (eta_o * cos_psi));
        kr = (Rs * Rs + Rp * Rp) / 2.0f;
    }

    return kr;
}

// Sampling of the GGX VNDF
[CudaDeviceExport] public func sampleGGXVNDF(Ve: float3, alpha: float, U1: float, U2: float) -> float3 {
    // The Ve argument is the view direction in tangent space, where the normal is (0, 0, 1).
    // Section 3.2: transforming the view direction to the hemisphere configuration.
    let Vh: float3 = normalize(float3(alpha * Ve.x, alpha * Ve.y, Ve.z));
    // Section 4.1: orthonormal basis (with special case if cross product is zero).
    let lensq: float = Vh.x * Vh.x + Vh.y * Vh.y;
    // Target plumbing: FlexLight's select for WGSL, renderer.cu's ternary elsewhere, whose branch nvcc fuses around
    var T1: float3;
    __target_switch {
    case wgsl: T1 = select(float3(1.0, 0.0, 0.0), float3(-Vh.y, Vh.x, 0.0) * inverseSqrt(lensq), lensq > 0.0);
    default: T1 = lensq > 0.0f ? float3(-Vh.y, Vh.x, 0.0f) * inverseSqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
    }
    let T2: float3 = cross(Vh, T1);
    // Section 4.2: parameterization of the projected area.
    let r: float = sqrt(U1);
    let phi: float = 2.0 * PI * U2;
    let t1: float = r * cos(phi);
    var t2: float = r * sin(phi);
    let s: float = 0.5 * (1.0 + Vh.z);
    t2 = (1.0 - s) * sqrt(max(0.0, 1.0 - t1 * t1)) + s * t2;
    // Section 4.3: reprojection onto hemisphere.
    // Target plumbing: unshared(t1) for t1, see unshared
    let Nh: float3 = t1 * T1 + t2 * T2 + sqrt(max(0.0, 1.0 - unshared(t1) * unshared(t1) - t2 * t2)) * Vh;
    // Section 3.4: transforming the normal back to the ellipsoid configuration.
    return normalize(float3(alpha * Nh.x, alpha * Nh.y, max(0.0, Nh.z)));
}

// Corresponding PDF is: pdf = cos(theta) / PI
[CudaDeviceExport] public func sampleCosWeightedHemisphere(random_1: float, random_2: float) -> float3 {
    let r = sqrt(random_1);
    let theta: float = 2.0f * PI * random_2;
    let x = r * cos(theta);
    let z = r * sin(theta);
    let y = sqrt(max(0.0f, 1.0f - x * x - z * z));
    return float3(x, y, z);
}

[CudaDeviceExport] public func tangentToWorld(v: float3, n: float3) -> float3 {
    var a: float3 = float3(0.0, 1.0, 0.0);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0, 0.0, 0.0);
    }
    let tangent: float3 = normalize(cross(n, a));
    let bitangent: float3 = cross(n, tangent);
    return v.x * tangent + v.y * n + v.z * bitangent;
}

[CudaDeviceExport] public func worldToTangent(v: float3, n: float3) -> float3 {
    var a: float3 = float3(0.0, 1.0, 0.0);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0, 0.0, 0.0);
    }
    let tangent: float3 = normalize(cross(n, a));
    let bitangent: float3 = cross(n, tangent);
    return float3(dot(v, tangent), dot(v, n), dot(v, bitangent));
}

// Build TBN matrix for tangent-space normal mapping. Uses triangle edges and UV deltas to compute
// tangent (U direction) and bitangent (V direction), with handedness fix.
[CudaDeviceExport] public func normalMapTBN(p0: float3, p1: float3, p2: float3, uv0: float2, uv1: float2, uv2: float2, n: float3) -> float3x3 {
    let e1: float3 = p1 - p0;
    let e2: float3 = p2 - p0;
    let duv1: float2 = uv1 - uv0;
    let duv2: float2 = uv2 - uv0;
    // Compute inverse determinant for UV to world space transformation.
    let det: float = duv1.x * duv2.y - duv1.y * duv2.x;
    let inv_det: float = 1.0f / det;
    var t: float3 = (e1 * duv2.y - e2 * duv1.y) * inv_det;
    let b_geom: float3 = (e2 * duv1.x - e1 * duv2.x) * inv_det;

    // Gram-Schmidt: make tangent perpendicular to interpolated normal.
    t = normalize(t - n * dot(n, t));
    // Handedness: ensure TBN is right-handed; flip T if geometric b disagrees with cross(n,t).
    if (dot(cross(n, t), b_geom) > 0.0f) {
        // Target plumbing: negate(x) for - x, see negate
        t = negate(t);
    }
    let b: float3 = cross(n, t);

    return float3x3(t, b, n);
}

[CudaDeviceExport] public func tangentToWorldNormalMap(v: float3, tbn: float3x3) -> float3 {
    return mul(v, tbn);
}

// BSDF times cosine toward out_dir as the path tracer samples it: the lobes of sampleBSDF on the side of the geometry normal
// out_dir lies on, evaluated by connectBSDF. random_state replays the visible normal steering the diffuse lobe choice.
[CudaDeviceExport] public func BSDF(in_dir: float3, out_dir: float3, n: float3, g_n: float3, material: Material, eta_i: float, eta_o: float, random_state: uint) -> float3 {
    // Test if v and l are on the same side of the surface
    // Target plumbing: negate(x) for - x, see negate
    if (dot(g_n, negate(in_dir)) * dot(g_n, out_dir) > 0.0f) {
        let diffuse: SampleBSDF = connectBSDF(in_dir, out_dir, n, material, eta_i, eta_o, 0u, random_state);
        let reflection: SampleBSDF = connectBSDF(in_dir, out_dir, n, material, eta_i, eta_o, 2u, random_state);
        return diffuse.throughput * diffuse.pdf + reflection.throughput * reflection.pdf;
    }
    let refraction: SampleBSDF = connectBSDF(in_dir, out_dir, n, material, eta_i, eta_o, 1u, random_state);
    return refraction.throughput * refraction.pdf;
}

__extern_cpp public struct SampleBSDF {
    __extern_cpp public float3 unit_direction;
    __extern_cpp public float3 throughput;
    __extern_cpp public uint random_state;
    __extern_cpp public bool refracted;
    __extern_cpp public uint lobe;
    // Solid angle density of the sampled lobe and direction, zero for delta lobes
    __extern_cpp public float pdf;
}

// Half vector dependent terms of sampleBSDF, shared with connections to a given direction
__extern_cpp public struct BSDFLobes {
    __extern_cpp public float v_dot_h;
    __extern_cpp public float n_dot_h;
    __extern_cpp public float3 refracted;
    __extern_cpp public float3 F;
    __extern_cpp public float F_greyscale;
    __extern_cpp public float reflect_weight;
    __extern_cpp public float diffuse_weight;
    __extern_cpp public float refract_weight;
    __extern_cpp public float colorless_reflection;
    __extern_cpp public float p_diffuse;
    __extern_cpp public float p_reflect;
    __extern_cpp public float p_refract;
}

[CudaDeviceExport] public func sampleHalfVector(v: float3, n_i: float3, alpha: float, inout random_state: uint) -> float3 {
    // Generate random values for sampling
    let random_h_1: Random = pcg(random_state);
    let random_h_2: Random = pcg(random_h_1.state);
    random_state = random_h_2.state;
    let v_tangent: float3 = worldToTangent(v, n_i);
    let ggx_n: float3 = sampleGGXVNDF(v_tangent.xzy, alpha, random_h_1.value, random_h_2.value).xzy;
    // Transform half vector back to world space
    return tangentToWorld(ggx_n, n_i);
}

[CudaDeviceExport] public func bsdfLobes(in_dir: float3, v: float3, n_i: float3, ggx_n: float3, material: Material, eta_i: float, eta_o: float) -> BSDFLobes {
    // Calculate shared half vector dot products
    let v_dot_h: float = dot(ggx_n, v);
    let n_dot_h: float = dot(n_i, ggx_n);
    // Try refraction through the properly oriented half vector
    let eta: float = eta_i / eta_o;
    let refracted: float3 = normalize(refract(in_dir, ggx_n, eta));
    // Calculate fresnel term
    var F: float3 = mix(float3(fresnel(abs(v_dot_h), eta_i, eta_o)), material.albedo, material.metallic);
    let F_greyscale: float = rgb_to_greyscale(F);
    // BSDF weights (these are artistic choices to balance the lobes)
    let reflect_weight: float = 1.0f;
    let diffuse_weight: float = (1.0f - material.transmission) * (1.0f - material.metallic);
    let refract_weight: float = material.transmission;
    // Add fresnel term for improved sampling performance
    let reflect_component: float = max(reflect_weight * F_greyscale, 0.0f);
    let diffuse_component: float = max(diffuse_weight * (1.0f - F_greyscale), 0.0f);
    let refract_component: float = max(refract_weight * (1.0f - F_greyscale) * sign(length(refracted)), 0.0f);
    // Do not account for chroma of reflection for transmissive materials as in this case our model uses albedo as proxy for absorption instead.
    var colorless_reflection: float = material.transmission;
    // Calculate sampling probabilities
    let total_component: float = reflect_component + diffuse_component + refract_component;
    let total_component_inv: float = 1.0f / max(total_component, BIAS);
    let p_diffuse: float = diffuse_component * total_component_inv;
    let p_reflect: float = reflect_component * total_component_inv;
    let p_refract: float = refract_component * total_component_inv;
    return BSDFLobes(v_dot_h, n_dot_h, refracted, F, F_greyscale, reflect_weight, diffuse_weight, refract_weight, colorless_reflection, p_diffuse, p_reflect, p_refract);
}

// Throughput of sampleBSDF leaving along l by lobe
[CudaDeviceExport] public func lobeThroughput(l: float3, n_i: float3, alpha: float, material: Material, lobes: BSDFLobes, lobe: uint) -> float3 {
    if (lobe == LOBE_DIFFUSE) {
        // BSDF = diffuse_weight * albedo / PI
        // => BSDF * n_dot_l = diffuse_weight * albedo * n_dot_l / PI

        // throughput = BSDF * n_dot_l / PDF
        //            = diffuse_weight * albedo * n_dot_l / PI / cosine_hemisphere.y * PI
        //            = diffuse_weight * albedo * n_dot_l / cosine_hemisphere.y

        // Since cosine_hemisphere.y is n_dot_l over the unit hemisphere, we can simplify the throughput to:
        // => throughput = albedo * diffuse_weight
        return lobes.diffuse_weight * material.albedo / lobes.p_diffuse;
    }
    if (lobe == LOBE_REFRACT) {
        let m_n_i_dot_l: float = - dot(n_i, l);
        // Microfacet term
        let G1_l: float = G1(alpha, max(m_n_i_dot_l, 0.0f));
        // BSDF = refract_weight * v_dot_h / n_dot_v / n_dot_l * D * G * (1 - F) * JACOBIAN
        // => BSDF * n_dot_l = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN

        // throughput = BSDF * n_dot_l / PDF
        //            = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN / G1_v / v_dot_h / D * n_dot_v / JACOBIAN
        //            = refract_weight * G * (1 - F) / G1_v

        // G = G1_v * G1_l
        // => throughput = refract_weight * G1_l * (1 - F)
        return float3(lobes.refract_weight * G1_l * (1.0f - lobes.F_greyscale) / lobes.p_refract);
    }
    let n_i_dot_l: float = dot(n_i, l);
    // Torrance-Sparrow
    let G1_l: float = G1(alpha, max(n_i_dot_l, 0.0f));
    // BSDF = reflect_weight * D * G * F / (4 * n_dot_v * n_dot_l)
    // => BSDF * n_dot_l = reflect_weight * D * G * F / (4 * n_dot_v)

    // throughput = BSDF * n_dot_l / PDF
    //            = reflect_weight * D * G * F / (4 * n_dot_v) / G1_v / D * (4 * n_dot_v)
    //            = reflect_weight * G * F / G1_v

    // G = G1_v * G1_l
    // => throughput = reflect_weight * G1_l * F
    return lobes.reflect_weight * G1_l * mix(lobes.F, float3(lobes.F_greyscale), lobes.colorless_reflection) / lobes.p_reflect;
}

// Solid angle density of sampleBSDF choosing lobe through the half vector of lobes, leaving with cosine n_i_dot_l (diffuse)
// or l_dot_h (refraction) toward its direction, zero for delta lobes.
[CudaDeviceExport] public func lobeDensity(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float, lobes: BSDFLobes, eta_i: float, eta_o: float, lobe: uint) -> float {
    if (lobe == LOBE_DIFFUSE) {
        // PDF_COSINE_HEMISPHERE = cosine_hemisphere.y / PI
        // => PDF = cosine_hemisphere.y / PI
        return select(0.0f, lobes.p_diffuse * n_i_dot_l * INV_PI, n_i_dot_v > 0.0f);
    }
    // Visible normal density of the GGX distribution for the sampled half vector
    let pdf_h: float = select(0.0f, smithG1(alpha, n_i_dot_v) * lobes.v_dot_h * trowbridgeReitz(alpha, lobes.n_dot_h) / n_i_dot_v, alpha > 0.0f && lobes.v_dot_h > 0.0f && lobes.n_dot_h > 0.0f && n_i_dot_v > 0.0f);
    if (lobe == LOBE_REFRACT) {
        // JACOBIAN = eta_o^2 * |l_dot_h| / (eta_i * v_dot_h + eta_o * l_dot_h)^2

        // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
        // PDF_REFRACT = PDF_VNDF * JACOBIAN
        //             = G1_v * v_dot_h * D / n_dot_v * JACOBIAN

        // PDF = PDF_REFRACT
        //     = G1_v * v_dot_h * D / n_dot_v * JACOBIAN
        let denom: float = eta_i * lobes.v_dot_h + eta_o * l_dot_h;
        return select(0.0f, lobes.p_refract * pdf_h * eta_o * eta_o * abs(l_dot_h) / (denom * denom), eta_i != eta_o && l_dot_h < 0.0f);
    }
    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
    // JACOBIAN = 1 / (4 * v_dot_h)
    // PDF_REFLECT = PDF_VNDF * JACOBIAN
    // => PDF_REFLECT = G1_v * D / (4 * n_dot_v)

    // PDF = PDF_REFLECT
    // => PDF = G1_v * D / (4 * v_dot_n)
    return select(0.0f, lobes.p_reflect * pdf_h / (4.0f * lobes.v_dot_h), pdf_h > 0.0f);
}

// SampleBSDF takes in incoming direction, surface normal, material and random state and returns an outgoing direction with throughput according to the BSDF for global illumination
[CudaDeviceExport] public func sampleBSDF(in_dir: float3, n: float3, material: Material, eta_i: float, eta_o: float, random_init: uint, screen_space: float2) -> SampleBSDF {
    var random_state: uint = random_init;
    // Basic dot products
    // Target plumbing: negate(x) for - x, see negate
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    var n_i: float3 = n * sign(n_dot_v);
    let n_i_dot_v: float = abs(n_dot_v);
    // Material constants
    let alpha: float = material.roughness * material.roughness;
    // Sample using GGX importance sampling for potential refractive or reflective case
    let ggx_n: float3 = sampleHalfVector(v, n_i, alpha, random_state);
    let lobes: BSDFLobes = bsdfLobes(in_dir, v, n_i, ggx_n, material, eta_i, eta_o);

    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    let random_p: Random = pcg(random_state);
    random_state = random_p.state;
    // Diffuse case
    if (random_p.value < lobes.p_diffuse) {
        let random_d_1: Random = pcg(random_state);
        let random_d_2: Random = pcg(random_d_1.state);
        sample.random_state = random_d_2.state;
        // Sample cosine weighted hemisphere
        let cosine_hemisphere: float3 = sampleCosWeightedHemisphere(random_d_1.value, random_d_2.value);
        sample.unit_direction = tangentToWorld(cosine_hemisphere, n_i);
        sample.throughput = lobeThroughput(sample.unit_direction, n_i, alpha, material, lobes, 0u);
        sample.pdf = lobeDensity(cosine_hemisphere.y, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o, 0u);
        return sample;
    }
    // Refractive case
    if (random_p.value < lobes.p_diffuse + lobes.p_refract) {
        // Refraction is valid
        sample.unit_direction = lobes.refracted;
        sample.pdf = lobeDensity(0.0f, dot(sample.unit_direction, ggx_n), n_i_dot_v, alpha, lobes, eta_i, eta_o, 1u);
        sample.throughput = lobeThroughput(sample.unit_direction, n_i, alpha, material, lobes, 1u);
        sample.random_state = random_state;
        sample.refracted = true;
        sample.lobe = 1u;
        return sample;
    }
    // Otherwise assume reflective case.
    sample.unit_direction = normalize(reflect(in_dir, ggx_n));
    sample.throughput = lobeThroughput(sample.unit_direction, n_i, alpha, material, lobes, 2u);
    sample.random_state = random_state;
    sample.lobe = 2u;
    sample.pdf = lobeDensity(0.0f, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o, 2u);
    return sample;
}

// The sample of sampleBSDF choosing lobe and leaving along out_dir, for connections to a given direction. The microfacet lobes
// take the half vector mapping in_dir to out_dir, diffuse samples replay the visible normal steering their lobe choice.
[CudaDeviceExport] public func connectBSDF(in_dir: float3, out_dir: float3, n: float3, material: Material, eta_i: float, eta_o: float, lobe: uint, random_init: uint) -> SampleBSDF {
    var random_state: uint = random_init;
    // Target plumbing: negate(x) for - x, see negate
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    let n_i: float3 = n * sign(n_dot_v);
    let alpha: float = material.roughness * material.roughness;
    var ggx_n: float3 = normalize(v + out_dir);
    if (lobe == LOBE_DIFFUSE) {
        ggx_n = sampleHalfVector(v, n_i, alpha, random_state);
    } else if (lobe == LOBE_REFRACT) {
        // Target plumbing: negate(x) for - x, see negate
        let h_t: float3 = negate(eta_i * v + eta_o * out_dir);
        ggx_n = normalize(h_t) * sign(dot(h_t, n_i));
    }
    let lobes: BSDFLobes = bsdfLobes(in_dir, v, n_i, ggx_n, material, eta_i, eta_o);
    let pdf: float = lobeDensity(dot(n_i, out_dir), dot(out_dir, ggx_n), abs(n_dot_v), alpha, lobes, eta_i, eta_o, lobe);
    // Directions sampleBSDF can't produce by lobe carry no throughput
    if (!(pdf > 0.0f)) {
        return SampleBSDF();
    }
    return SampleBSDF(out_dir, lobeThroughput(out_dir, n_i, alpha, material, lobes, lobe), random_state, lobe == LOBE_REFRACT, lobe, pdf);
}

// Decide between next event estimation and emission on the next hit, as the path tracer does
[CudaDeviceExport] public func neeDecision(material: Material, n_dot_v: float, eta_i: float, eta_o: float) -> bool {
    // Calculate fresnel term
    let F_n: float3 = mix(float3(fresnel(abs(n_dot_v), eta_i, eta_o)), material.albedo, material.metallic);
    let F_n_greyscale: float = rgb_to_greyscale(F_n);
    let diffuse_factor_estimate: float = max((1.0f - F_n_greyscale) * (1.0f - material.metallic) * (1.0f - material.transmission), 0.0f);
    return diffuse_factor_estimate > 0.04f || material.roughness > 0.2f;
}

public static const uint LOBE_DIFFUSE = 0u;
public static const uint LOBE_REFRACT = 1u;

// Bit offsets of the packed path description
public static const uint PATH_END = 0u;
public static const uint PATH_TYPE = 12u;

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

[CudaDeviceExport] public func hash(x: uint) -> uint {
    let state: uint = x * 747796405u + 2891336453u;
    let word: uint = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}

[CudaDeviceExport] public func stream(seed: uint, index: uint) -> uint {
    return hash(seed ^ hash(index));
}

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
