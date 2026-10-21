module pathtracer;

public static const float PI = 3.141592653589793;
public static const float MAX_SAFE_INTEGER_FOR_F32 = 8388607.0;
public static const uint UINT_MAX = 4294967295u;
public static const float BIAS = 0.0000152587890625;
public static const float INV_PI = 0.3183098861837907;

public static const uint LOBE_DIFFUSE = 0u;
public static const uint LOBE_REFRACT = 1u;
public static const uint LOBE_REFLECT = 2u;

__target_intrinsic(wgsl, "Material")
__target_intrinsic(cuda, "BSDFMaterial")
__extern_cpp public struct Material {
    __extern_cpp public float3 albedo;
    __extern_cpp public float3 emissive;
    __extern_cpp public float roughness;
    __extern_cpp public float metallic;
    __extern_cpp public float transmission;
    __extern_cpp public float ior;
    __extern_cpp public float3 absorption;
};

__extern_cpp public struct RandomSphere {
    __extern_cpp public uint state;
    __extern_cpp public float3 value;
};

__extern_cpp public struct SampleBSDF {
    __extern_cpp public float3 unit_direction;
    __extern_cpp public float3 throughput;
    __extern_cpp public uint random_state;
    __extern_cpp public bool refracted;
    __extern_cpp public uint lobe;
    // Solid angle PDF, 0 for delta lobes
    __extern_cpp public float pdf;
}

public float3 normalize(float3 a) {
    __target_switch {
    case cuda: __intrinsic_asm "(($0) * make_float3(rnorm3df(($0).x, ($0).y, ($0).z)))";
    case wgsl: __intrinsic_asm "normalize($0)";
    default: return a * (1.0f / sqrt(dot(a, a)));
    }
}
public float inverseSqrt(float x) {
    __target_switch {
    case cuda: __intrinsic_asm "rsqrtf($0)";
    case wgsl: __intrinsic_asm "inverseSqrt($0)";
    default: return 1.0f / sqrt(x);
    }
}
[ForceInline] public float select(float f, float t, bool cond) { return select(cond, t, f); }
[ForceInline] public float3 select(float3 f, float3 t, bool cond) { return select(cond, t, f); }
[ForceInline] public float3 select(float3 f, float3 t, bool3 cond) { return select(cond, t, f); }
public float unshared(float x) {
    __target_switch {
    case wgsl: __intrinsic_asm "$0";
    default: return x;
    }
}
public float3 negate(float3 x) {
    __target_switch {
    case wgsl: __intrinsic_asm "(-$0)";
    default: return -x;
    }
}
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

__extern_cpp public struct Random {
    __extern_cpp public uint state;
    __extern_cpp public float value;
};

[CudaDeviceExport] public func rgb_to_greyscale(rgb: float3) -> float {
    return dot(rgb, float3(0.299, 0.587, 0.114));
}

[CudaDeviceExport] public Random pcg(uint state) {
    __target_switch {
    case wgsl:
    // PCG random number generator
    // Reference: http://www.pcg-random.org/
    return Random(state * 747796405u + 2891336453u, float(hash(state)) / float(UINT_MAX));
    default:
        const float value = ((state = hash(state)) >> 8) * 0x1p-24f;
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

[CudaDeviceExport] public func trowbridgeReitz(alpha: float, n_dot_h: float) -> float {
    let numerator: float = alpha * alpha;
    // D = alpha^2 / (PI * (n_dot_h^2 * (alpha^2 - 1) + 1)^2)
    // n_dot_h^2 * (alpha^2 - 1) + 1 = (1 - n_dot_h) * (1 + n_dot_h) + alpha^2 * n_dot_h^2
    // => D = numerator / max(PI * denom^2, LEAST_NORMAL), finite as alpha -> 0
    let denom: float = (1.0f - n_dot_h) * (1.0f + n_dot_h) + numerator * n_dot_h * n_dot_h;
    return numerator / max(PI * denom * denom, 1.17549435e-38f);
}

[CudaDeviceExport] public func G1(alpha: float, n_dot_x: float) -> float {
    let k: float = alpha * 0.5f;
    return n_dot_x / max(n_dot_x * (1.0f - k) + k, BIAS);
}

// Smith masking of GGX
// G1 = 2 * n_dot_x / (n_dot_x + sqrt(alpha^2 + (1 - alpha^2) * n_dot_x^2))
// alpha = 0 => G1 = 1
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
        // Index-matched: no bend, so cos_psi is cos_theta exactly, lest rounding near grazing reflect
        let cos_psi = select(sqrt(max(0.0f, 1.0f - sin_psi * sin_psi)), cos_theta, eta_i == eta_o);
        // cos = abs(cosi);
        let Rs = ((eta_o * cos_theta) - (eta_i * cos_psi)) / ((eta_o * cos_theta) + (eta_i * cos_psi));
        let Rp = ((eta_i * cos_theta) - (eta_o * cos_psi)) / ((eta_i * cos_theta) + (eta_o * cos_psi));
        kr = (Rs * Rs + Rp * Rp) / 2.0f;
    }

    return kr;
}

// Sampling the GGX VNDF (Heitz 2018, Listing 1)
// Output Ne: normal sampled with PDF D_Ve(Ne) = G1(Ve) * max(0, dot(Ve, Ne)) * D(Ne) / Ve.z
[CudaDeviceExport] public func sampleGGXVNDF(Ve: float3, alpha: float, U1: float, U2: float) -> float3 {
    // The Ve argument is the view direction in tangent space, where the normal is (0, 0, 1).
    // Section 3.2: transforming the view direction to the hemisphere configuration.
    let Vh: float3 = normalize(float3(alpha * Ve.x, alpha * Ve.y, Ve.z));
    // Section 4.1: orthonormal basis (with special case if cross product is zero).
    let lensq: float = Vh.x * Vh.x + Vh.y * Vh.y;
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

// Tangent frame of the normal map from the triangle's edges and UV deltas
[CudaDeviceExport] public func normalMapTBN(p0: float3, p1: float3, p2: float3, uv0: float2, uv1: float2, uv2: float2, n: float3) -> float3x3 {
    let e1: float3 = p1 - p0;
    let e2: float3 = p2 - p0;
    let duv1: float2 = uv1 - uv0;
    let duv2: float2 = uv2 - uv0;
    let det: float = duv1.x * duv2.y - duv1.y * duv2.x;
    let inv_det: float = 1.0f / det;
    var t: float3 = (e1 * duv2.y - e2 * duv1.y) * inv_det;
    let b_geom: float3 = (e2 * duv1.x - e1 * duv2.x) * inv_det;

    // Gram-Schmidt: make tangent perpendicular to interpolated normal.
    t = normalize(t - n * dot(n, t));
    // Handedness: ensure TBN is right-handed; flip T if geometric b disagrees with cross(n,t).
    if (dot(cross(n, t), b_geom) > 0.0f) {
        // Refractive half-vector (eq. 16)
        t = negate(t);
    }
    let b: float3 = cross(n, t);

    return float3x3(t, b, n);
}

[CudaDeviceExport] public func tangentToWorldNormalMap(v: float3, tbn: float3x3) -> float3 {
    return mul(v, tbn);
}

// Each lobe toward out_dir: its throughput and PDF_lobe in the diffuse, refraction and reflection slots,
// PDF_lobe = 0 where it doesn't reach out_dir
// out_dir across the face (refracted): the refraction
// otherwise: the diffuse and the reflection
// as throughput = BSDF_lobe * n_dot_l / PDF_lobe
// => BSDF * n_dot_l = sum throughput * PDF_lobe
[CudaDeviceExport] public func BSDF(in_dir: float3, out_dir: float3, n: float3, material: Material, eta_i: float,
    eta_o: float, refracted: bool, random_state: uint, out throughputs: float3[3], out pdfs: float[3]) -> float3 {
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    let n_i: float3 = n * sign(n_dot_v);
    let n_i_dot_l: float = dot(n_i, out_dir);
    let alpha: float = material.roughness * material.roughness;
    let lobes: uint = 3u;
    for (var i: uint = 0u; i < 3u; i++) {
        throughputs[i] = float3(0.0f);
        pdfs[i] = 0.0f;
    }
    // The lobe's half vector and its terms, taken again only where they differ from the last lobe's
    var half_of: uint = UINT_MAX;
    var ggx_n: float3 = float3(0.0f);
    var lobe_terms: BSDFLobes = {};
    for (var i: uint = 0u; i < lobes; i++) {
        let lobe: uint = i;
        if ((lobe == LOBE_REFRACT) != refracted) {
            continue;
        }
        // sampleBSDF's half vector for the diffuse lobe, out_dir's reflective one for reflection
        let lobe_half: uint = lobe;
        if (lobe_half != half_of) {
            if (lobe_half == LOBE_DIFFUSE) {
                ggx_n = sampledHalf(in_dir, n, material, random_state);
            } else if (lobe_half == LOBE_REFRACT) {
                ggx_n = refractedHalf(in_dir, out_dir, n, eta_i, eta_o);
            } else {
                ggx_n = reflectedHalf(in_dir, out_dir);
            }
            lobe_terms = bsdfLobes(in_dir, negate(in_dir), n_i, ggx_n, material, eta_i, eta_o);
            half_of = lobe_half;
        }
        switch (lobe) {
        case LOBE_DIFFUSE:
            pdfs[0] = diffusePDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughputs[0] = diffuseBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        case LOBE_REFRACT:
            pdfs[1] = refractPDF(n_i_dot_l, dot(out_dir, ggx_n), abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughputs[1] = refractBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        default:
            pdfs[2] = reflectPDF(n_i_dot_l, 0.0f, abs(n_dot_v), alpha, lobe_terms, eta_i, eta_o);
            throughputs[2] = reflectBSDF(out_dir, n_i, alpha, material, lobe_terms);
            break;
        }
    }
    // Directions a lobe can't sample carry no throughput
    var f: float3 = float3(0.0f);
    for (var i: uint = 0u; i < 3u; i++) {
        if (pdfs[i] > 0.0f) {
            f += throughputs[i] * pdfs[i];
        }
    }
    return f;
}

// Half vector terms of sampleBSDF, shared with the lobes' evaluation toward a given out_dir
__extern_cpp public struct BSDFLobes {
    __extern_cpp public float v_dot_h;
    __extern_cpp public float n_dot_h;
    __extern_cpp public float3 refracted;
    __extern_cpp public float3 F;
    __extern_cpp public float F_greyscale;
    __extern_cpp public float reflect_weight;
    __extern_cpp public float diffuse_weight;
    __extern_cpp public float refract_weight;
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
    // Calculate sampling probabilities
    let total_component: float = reflect_component + diffuse_component + refract_component;
    let total_component_inv: float = 1.0f / max(total_component, BIAS);
    let p_diffuse: float = diffuse_component * total_component_inv;
    let p_reflect: float = reflect_component * total_component_inv;
    let p_refract: float = refract_component * total_component_inv;
    return BSDFLobes(v_dot_h, n_dot_h, refracted, F, F_greyscale, reflect_weight, diffuse_weight, refract_weight, p_diffuse, p_reflect, p_refract);
}

// Each lobe by three functions under each other: XBSDF, its throughput toward l, XSample, sampleBSDF's case drawing
// it, and XPDF, its solid angle PDF, 0 for delta lobes; all three on the half vector terms of one half vector

// PDF_VNDF of the half vector of lobes, the refraction's and the reflection's
[CudaDeviceExport] public func vndfPDF(n_i_dot_v: float, alpha: float, lobes: BSDFLobes) -> float {
    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
    let pdf_h: float = select(0.0f, smithG1(alpha, n_i_dot_v) * lobes.v_dot_h * trowbridgeReitz(alpha, lobes.n_dot_h) / n_i_dot_v, alpha > 0.0f && lobes.v_dot_h > 0.0f && lobes.n_dot_h > 0.0f && n_i_dot_v > 0.0f);
    return pdf_h;
}

[CudaDeviceExport] public func diffuseBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: BSDFLobes) -> float3 {
    // BSDF = diffuse_weight * albedo / PI
    // => BSDF * n_dot_l = diffuse_weight * albedo * n_dot_l / PI

    // throughput = BSDF * n_dot_l / PDF
    //            = diffuse_weight * albedo * n_dot_l / PI / cosine_hemisphere.y * PI
    //            = diffuse_weight * albedo * n_dot_l / cosine_hemisphere.y

    // Since cosine_hemisphere.y is n_dot_l over the unit hemisphere, we can simplify the throughput to:
    // => throughput = albedo * diffuse_weight
    return lobes.diffuse_weight * material.albedo / lobes.p_diffuse;
}

// Diffuse case of sampleBSDF
[CudaDeviceExport] public func diffuseSample(n_i: float3, n_i_dot_v: float, alpha: float, material: Material,
    lobes: BSDFLobes, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    let random_d_1: Random = pcg(random_state);
    let random_d_2: Random = pcg(random_d_1.state);
    sample.random_state = random_d_2.state;
    // Sample cosine weighted hemisphere
    let cosine_hemisphere: float3 = sampleCosWeightedHemisphere(random_d_1.value, random_d_2.value);
    sample.unit_direction = tangentToWorld(cosine_hemisphere, n_i);
    sample.lobe = LOBE_DIFFUSE;
    sample.throughput = diffuseBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = diffusePDF(cosine_hemisphere.y, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func diffusePDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: BSDFLobes, eta_i: float, eta_o: float) -> float {
    // PDF_COSINE_HEMISPHERE = cosine_hemisphere.y / PI
    // => PDF = cosine_hemisphere.y / PI
    return select(0.0f, lobes.p_diffuse * n_i_dot_l * INV_PI, n_i_dot_v > 0.0f);
}


[CudaDeviceExport] public func refractBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: BSDFLobes) -> float3 {
    let m_n_i_dot_l: float = - dot(n_i, l);
    // Microfacet term
    let G1_l: float = G1(alpha, max(m_n_i_dot_l, 0.0f));
    // BSDF = refract_weight * v_dot_h / n_dot_v / n_dot_l * D * G * (1 - F) * JACOBIAN * albedo
    // => BSDF * n_dot_l = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN * albedo

    // throughput = BSDF * n_dot_l / PDF
    //            = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN * albedo / G1_v / v_dot_h / D * n_dot_v / JACOBIAN
    //            = refract_weight * G * (1 - F) * albedo / G1_v

    // G = G1_v * G1_l
    return lobes.refract_weight * G1_l * (1.0f - lobes.F_greyscale) * material.albedo / lobes.p_refract;
}

// Refractive case of sampleBSDF, through its half vector ggx_n
[CudaDeviceExport] public func refractSample(ggx_n: float3, n_i: float3, n_i_dot_v: float, alpha: float,
    material: Material, lobes: BSDFLobes, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    // Refraction is valid
    sample.unit_direction = lobes.refracted;
    sample.random_state = random_state;
    sample.refracted = true;
    sample.lobe = LOBE_REFRACT;
    sample.throughput = refractBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = refractPDF(0.0f, dot(sample.unit_direction, ggx_n), n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func refractPDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: BSDFLobes, eta_i: float, eta_o: float) -> float {
    let pdf_h: float = vndfPDF(n_i_dot_v, alpha, lobes);
    // JACOBIAN = eta_o^2 * |l_dot_h| / (eta_i * v_dot_h + eta_o * l_dot_h)^2

    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
    // PDF_REFRACT = PDF_VNDF * JACOBIAN
    //             = G1_v * v_dot_h * D / n_dot_v * JACOBIAN

    // PDF = PDF_REFRACT
    //     = G1_v * v_dot_h * D / n_dot_v * JACOBIAN
    let denom: float = eta_i * lobes.v_dot_h + eta_o * l_dot_h;
    return select(0.0f, lobes.p_refract * pdf_h * eta_o * eta_o * abs(l_dot_h) / (denom * denom), eta_i != eta_o && l_dot_h < 0.0f);
}

[CudaDeviceExport] public func reflectBSDF(l: float3, n_i: float3, alpha: float, material: Material,
    lobes: BSDFLobes) -> float3 {
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
    return lobes.reflect_weight * G1_l * lobes.F / lobes.p_reflect;
}

// Reflective case of sampleBSDF, off its half vector ggx_n
[CudaDeviceExport] public func reflectSample(in_dir: float3, ggx_n: float3, n_i: float3, n_i_dot_v: float, alpha: float,
    material: Material, lobes: BSDFLobes, eta_i: float, eta_o: float, random_state: uint) -> SampleBSDF {
    var sample: SampleBSDF = SampleBSDF(float3(1.0f), float3(1.0f), 0u, false, 0u, 0.0f);
    sample.unit_direction = normalize(reflect(in_dir, ggx_n));
    sample.random_state = random_state;
    sample.lobe = LOBE_REFLECT;
    sample.throughput = reflectBSDF(sample.unit_direction, n_i, alpha, material, lobes);
    sample.pdf = reflectPDF(0.0f, 0.0f, n_i_dot_v, alpha, lobes, eta_i, eta_o);
    return sample;
}

[CudaDeviceExport] public func reflectPDF(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float,
    lobes: BSDFLobes, eta_i: float, eta_o: float) -> float {
    let pdf_h: float = vndfPDF(n_i_dot_v, alpha, lobes);
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
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    var n_i: float3 = n * sign(n_dot_v);
    let n_i_dot_v: float = abs(n_dot_v);
    // Material constants
    let alpha: float = material.roughness * material.roughness;
    // Sample using GGX importance sampling for potential refractive or reflective case
    let ggx_n: float3 = sampleHalfVector(v, n_i, alpha, random_state);
    let lobes: BSDFLobes = bsdfLobes(in_dir, v, n_i, ggx_n, material, eta_i, eta_o);

    let random_p: Random = pcg(random_state);
    random_state = random_p.state;
    // Diffuse case
    if (random_p.value < lobes.p_diffuse) {
        return diffuseSample(n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
    }
    // Refractive case
    if (random_p.value < lobes.p_diffuse + lobes.p_refract) {
        return refractSample(ggx_n, n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
    }
    // Otherwise assume reflective case.
    return reflectSample(in_dir, ggx_n, n_i, n_i_dot_v, alpha, material, lobes, eta_i, eta_o, random_state);
}

// sampleBSDF's half vector, drawn from random_state as sampleBSDF draws it: the diffuse lobe's
[CudaDeviceExport] public func sampledHalf(in_dir: float3, n: float3, material: Material,
    random_state: uint) -> float3 {
    var state: uint = random_state;
    let v: float3 = negate(in_dir);
    // Diffuse half-vector of sampleBSDF
    return sampleHalfVector(v, n * sign(dot(n, v)), material.roughness * material.roughness, state);
}

// The reflection's half vector of out_dir
[CudaDeviceExport] public func reflectedHalf(in_dir: float3, out_dir: float3) -> float3 {
    // Reflective half-vector
    return normalize(negate(in_dir) + out_dir);
}

// The refraction's half vector of out_dir, facing n_i
[CudaDeviceExport] public func refractedHalf(in_dir: float3, out_dir: float3, n: float3, eta_i: float, eta_o: float)
    -> float3 {
    let v: float3 = negate(in_dir);
    // Refractive half-vector (eq. 16)
    let h_t: float3 = negate(eta_i * v + eta_o * out_dir);
    return normalize(h_t) * sign(dot(h_t, n * sign(dot(n, v))));
}

// I = L * PI * radius^2, the sphere's projected area
// => L = color * intensity / (PI * radius^2)
[CudaDeviceExport] public func pointLightRadiance(color: float3, intensity: float, radius: float) -> float3 {
    return color * intensity / (PI * radius * radius);
}

// If the ray is inside a medium, apply Beer's law for absorption.
[CudaDeviceExport] public func beerLambert(distance: float, absorption: float3) -> float3 {
    // The amount of light transmitted is T = exp(-sigma_a * d).
    // sigma_a = -ln(absorption)
    let absorption_coefficient: float3 = max(absorption, float3(BIAS));
    return exp(distance * log(absorption_coefficient));
}

// Decide between next event estimation and emission on the next hit, as the path tracer does
[CudaDeviceExport] public func neeDecision(material: Material, n_dot_v: float, eta_i: float, eta_o: float) -> bool {
    // Calculate fresnel term
    let F_n: float3 = mix(float3(fresnel(abs(n_dot_v), eta_i, eta_o)), material.albedo, material.metallic);
    let F_n_greyscale: float = rgb_to_greyscale(F_n);
    let diffuse_factor_estimate: float = max((1.0f - F_n_greyscale) * (1.0f - material.metallic) * (1.0f - material.transmission), 0.0f);
    return diffuse_factor_estimate > 0.04f || material.roughness > 0.2f;
}

// eta_i = eta_o => F = 0, l = -v
// => throughput = transmission * (1 - metallic) * G1_l * albedo
[CudaDeviceExport] public func straightThrough(dir: float3, n: float3, material: Material) -> float3 {
    let F_greyscale: float = rgb_to_greyscale(material.albedo * material.metallic);
    return material.transmission * G1(material.roughness * material.roughness, abs(dot(n, dir))) * (1.0f - F_greyscale) * material.albedo;
}

public static const uint PATH_END = 0u;
public static const uint PATH_TYPE = 12u;

__target_intrinsic(cuda, "Reservoir")
__extern_cpp public struct Reservoir {
    __extern_cpp public uint seed;
    __extern_cpp public uint path;
    __extern_cpp public float w;
    __extern_cpp public float c;
    __extern_cpp public float3 f;
    __extern_cpp public float jac;
    __extern_cpp public uint4 rc;
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

[CudaDeviceExport] public func offer(inout sel: Selection, candidate: Reservoir, weight: float3) {
    let w: float = rgb_to_greyscale(weight);
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


static const float RESTIR_ROUGHNESS = 0.2;
static const float RESTIR_FOOTPRINT = 0.0025132741228718345;

[CudaDeviceExport] public func facingSign(transmission: float, face: float3, direction: float3) -> float {
    return transmission > 0.0f || dot(face, direction) < 0.0f ? 1.0f : -1.0f;
}

[CudaDeviceExport] public func survivalProbability(throughput: float3, density: float) -> float {
    __target_switch {
    case wgsl:
    let importancy_factor: float3 = throughput / density;
    return clamp(max(importancy_factor.x, max(importancy_factor.y, importancy_factor.z)), 0.0f, 1.0f);
    default:
    return min(max(max(throughput.x, max(throughput.y, throughput.z)) / density, 0.0f), 1.0f);
    }
}


__target_intrinsic(cuda, "LightNode")
__extern_cpp public struct LightBounds {
    __extern_cpp public float3 low;
    __extern_cpp public float3 high;
    __extern_cpp public float3 w;
    __extern_cpp public float phi;
    __extern_cpp public float cos_theta_o;
};

[CudaDeviceExport] public func cosSubClamped(sin_a: float, cos_a: float, sin_b: float, cos_b: float) -> float {
    return select(cos_a * cos_b + sin_a * sin_b, 1.0f, cos_a > cos_b);
}
[CudaDeviceExport] public func sine(c: float) -> float {
    return sqrt(max(1.0f - c * c, 0.0f));
}

[CudaDeviceExport] public func importance(node: LightBounds, p: float3, normal: float3) -> float {
    let center: float3 = (node.low + node.high) * 0.5f;
    let diagonal: float3 = node.high - node.low;
    let wi: float3 = normalize(p - center);
    let d2: float = dot(p - center, p - center);
    let r2: float = dot(diagonal, diagonal) / 4.0f;
    let cos_theta_w: float = abs(dot(node.w, wi));
    let sin_theta_o: float = sine(node.cos_theta_o);
    let cos_theta_b: float = select(sqrt(max(1.0f - r2 / d2, 0.0f)), -1.0f, d2 < r2);
    let sin_theta_b: float = sine(cos_theta_b);
    let cos_theta_x: float = cosSubClamped(sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
    let sin_theta_x: float = select(sine(cos_theta_w) * node.cos_theta_o - cos_theta_w * sin_theta_o, 0.0f, cos_theta_w > node.cos_theta_o);
    let cos_theta_p: float = cosSubClamped(sin_theta_x, cos_theta_x, sin_theta_b, cos_theta_b);
    if (cos_theta_p <= 0.0f) {
        return 0.0f;
    }
    let cos_theta_i: float = - dot(wi, normal);
    return max(node.phi * cos_theta_p / max(d2, length(diagonal) / 2.0f)
        * select(cosSubClamped(sine(cos_theta_i), cos_theta_i, sin_theta_b, cos_theta_b), 1.0f, dot(normal, normal) == 0.0f), 0.0f);
}

[CudaDeviceExport] public func solidAngle(probability: float, normal: float3, toward: float3) -> float {
    return 2.0f * probability * pow(length(toward), 3.0f) / abs(dot(normal, toward));
}

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

[CudaDeviceExport] public func childShare(first: LightBounds, second: LightBounds, p: float3, normal: float3, child: uint) -> float {
    let shares: float2 = float2(importance(first, p, normal), importance(second, p, normal));
    return select(0.0f, shares[child] / (shares.x + shares.y), shares[child] > 0.0f);
}

[CudaDeviceExport] public func powerHeuristic(a: float, b: float) -> float {
    return select(1.0f, 1.0f / (1.0f + (b / a) * (b / a)), b > 0.0f);
}

[CudaDeviceExport] public func sphereDensity(center: float3, radius: float, p: float3) -> float {
    let sin2: float = radius * radius / dot(center - p, center - p);
    if (sin2 >= 1.0f) {
        return 0.25f / PI;
    }
    return (1.0f + sqrt(1.0f - sin2)) / (2.0f * PI * sin2);
}

[CudaDeviceExport] public func sampleSphere(center: float3, radius: float, p: float3, u1: float, u2: float) -> float3 {
    let sin2: float = radius * radius / dot(center - p, center - p);
    let one_minus_cos: float = select(u1 * sin2 / (1.0f + sqrt(max(1.0f - sin2, 0.0f))), 2.0f * u1, sin2 >= 1.0f);
    let sin_theta: float = sqrt(max(one_minus_cos * (2.0f - one_minus_cos), 0.0f));
    let phi: float = 2.0f * PI * u2;
    return tangentToWorld(float3(sin_theta * cos(phi), 1.0f - one_minus_cos, sin_theta * sin(phi)), normalize(center - p));
}
