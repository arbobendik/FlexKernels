module pathtracer;

public static const float PI = 3.141592653589793;
public static const float MAX_SAFE_INTEGER_FOR_F32 = 8388607.0;
public static const uint UINT_MAX = 4294967295u;
public static const float BIAS = 0.0000152587890625;
public static const float INV_PI = 0.3183098861837907;

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

float random(inout uint state) { return ((state = hash(state)) >> 8) * 0x1p-24f; }

[CudaDeviceExport] public Random pcg(uint state) {
    __target_switch {
    case wgsl:
    // PCG random number generator
    // Reference: http://www.pcg-random.org/
    return Random(state * 747796405u + 2891336453u, float(hash(state)) / float(UINT_MAX));
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
        return RandomHemisphere(random_sphere.state, negate(random_sphere.value));
    }
}

[CudaDeviceExport] public func trowbridgeReitz(alpha: float, n_dot_h: float) -> float {
    let numerator: float = alpha * alpha;
    // D = alpha^2 / (PI * (n_dot_h^2 * (alpha^2 - 1) + 1)^2)
    // n_dot_h^2 * (alpha^2 - 1) + 1 = (1 - n_dot_h) * (1 + n_dot_h) + alpha^2 * n_dot_h^2
    // => D = numerator / max(PI * denom^2, LEAST_NORMAL), finite as alpha -> 0
    let denom: float = (1.0f - n_dot_h) * (1.0f + n_dot_h) + numerator * n_dot_h * n_dot_h;
    return numerator / max(PI * denom * denom, 1.17549435e-38f);
}

// Smith masking of GGX
// G1 = 2 * n_dot_x / (n_dot_x + sqrt(alpha^2 + (1 - alpha^2) * n_dot_x^2))
// alpha = 0 => G1 = 1
[CudaDeviceExport] public func smithG1(alpha: float, n_dot_x: float) -> float {
    let alpha_sq: float = alpha * alpha;
    let g1: float = 2.0f * n_dot_x / (n_dot_x + sqrt(alpha_sq + (1.0f - alpha_sq) * n_dot_x * n_dot_x));
    return select(1.0f, g1, alpha > 0.0f);
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

// Offset along the smooth normal to prevent unnatural hard shadow / reflection borders due to the difference
// between the smooth normal and geometry
[CudaDeviceExport] public func geometryOffset(t0: float3, t1: float3, t2: float3, n0: float3, n1: float3, n2: float3, geometry_n: float3, uvw: float3, position: float3) -> float {
    let edge1: float3 = t1 - t0;
    let edge2: float3 = t2 - t0;
    let edge3: float3 = t2 - t1;
    let min_edge_length: float = min(length(edge1), min(length(edge2), length(edge3)));
    let diffs: float3 = float3(distance(position, t0), distance(position, t1), distance(position, t2));
    let angles: float3 = acos(abs(float3(dot(geometry_n, normalize(n0)), dot(geometry_n, normalize(n1)), dot(geometry_n, normalize(n2)))));
    // Limit angles to 45 degrees
    let angle_tan: float3 = clamp(tan(angles), float3(0.0f), float3(PI * 0.25f));
    // Keep geometry offset within reasonable range
    return clamp(dot(diffs * angle_tan, uvw), 0.0f, min_edge_length * 0.125f);
}

// out_dir on in_dir's side of g_n: BSDF * n_dot_l = throughput_diffuse * PDF_diffuse + throughput_reflect * PDF_reflect
// otherwise: BSDF * n_dot_l = throughput_refract * PDF_refract
// as throughput = BSDF_lobe * n_dot_l / PDF_lobe
[CudaDeviceExport] public func BSDF(in_dir: float3, out_dir: float3, n: float3, g_n: float3, material: Material, eta_i: float, eta_o: float, random_state: uint) -> float3 {
    // Test if v and l are on the same side of the surface
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
    // Solid angle PDF, 0 for delta lobes
    __extern_cpp public float pdf;
}

// Half vector terms of sampleBSDF, shared with connectBSDF
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
        let G1_l: float = smithG1(alpha, max(m_n_i_dot_l, 0.0f));
        // BSDF = refract_weight * v_dot_h / n_dot_v / n_dot_l * D * G * (1 - F) * JACOBIAN * albedo
        // => BSDF * n_dot_l = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN * albedo

        // throughput = BSDF * n_dot_l / PDF
        //            = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN * albedo / G1_v / v_dot_h / D * n_dot_v / JACOBIAN
        //            = refract_weight * G * (1 - F) * albedo / G1_v

        // G = G1_v * G1_l
        return lobes.refract_weight * G1_l * (1.0f - lobes.F_greyscale) * material.albedo / lobes.p_refract;
    }
    let n_i_dot_l: float = dot(n_i, l);
    // Torrance-Sparrow
    let G1_l: float = smithG1(alpha, max(n_i_dot_l, 0.0f));
    // BSDF = reflect_weight * D * G * F / (4 * n_dot_v * n_dot_l)
    // => BSDF * n_dot_l = reflect_weight * D * G * F / (4 * n_dot_v)

    // throughput = BSDF * n_dot_l / PDF
    //            = reflect_weight * D * G * F / (4 * n_dot_v) / G1_v / D * (4 * n_dot_v)
    //            = reflect_weight * G * F / G1_v

    // G = G1_v * G1_l
    // => throughput = reflect_weight * G1_l * F
    return lobes.reflect_weight * G1_l * lobes.F / lobes.p_reflect;
}

// Solid angle PDF of sampleBSDF choosing lobe, 0 for delta lobes
[CudaDeviceExport] public func lobeDensity(n_i_dot_l: float, l_dot_h: float, n_i_dot_v: float, alpha: float, lobes: BSDFLobes, eta_i: float, eta_o: float, lobe: uint) -> float {
    if (lobe == LOBE_DIFFUSE) {
        // PDF_COSINE_HEMISPHERE = cosine_hemisphere.y / PI
        // => PDF = cosine_hemisphere.y / PI
        return select(0.0f, lobes.p_diffuse * n_i_dot_l * INV_PI, n_i_dot_v > 0.0f);
    }
    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
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

// sampleBSDF's lobe toward a given out_dir, for connections
[CudaDeviceExport] public func connectBSDF(in_dir: float3, out_dir: float3, n: float3, material: Material, eta_i: float, eta_o: float, lobe: uint, random_init: uint) -> SampleBSDF {
    var random_state: uint = random_init;
    // Refractive half-vector (eq. 16)
    let v: float3 = negate(in_dir);
    let n_dot_v: float = dot(n, v);
    let n_i: float3 = n * sign(n_dot_v);
    let alpha: float = material.roughness * material.roughness;
    var ggx_n: float3 = normalize(v + out_dir);
    if (lobe == LOBE_DIFFUSE) {
        ggx_n = sampleHalfVector(v, n_i, alpha, random_state);
    } else if (lobe == LOBE_REFRACT) {
        // Refractive half-vector (eq. 16)
        let h_t: float3 = negate(eta_i * v + eta_o * out_dir);
        ggx_n = normalize(h_t) * sign(dot(h_t, n_i));
    }
    let lobes: BSDFLobes = bsdfLobes(in_dir, v, n_i, ggx_n, material, eta_i, eta_o);
    let pdf: float = lobeDensity(dot(n_i, out_dir), dot(out_dir, ggx_n), abs(n_dot_v), alpha, lobes, eta_i, eta_o, lobe);
    // Directions the lobe can't sample carry no throughput
    if (!(pdf > 0.0f)) {
        return SampleBSDF();
    }
    return SampleBSDF(out_dir, lobeThroughput(out_dir, n_i, alpha, material, lobes, lobe), random_state, lobe == LOBE_REFRACT, lobe, pdf);
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

// Light sampling except at smooth mirrors and glass, whose lobes are delta
[CudaDeviceExport] public func samplesLights(material: Material) -> bool {
    return material.roughness > 0.0f || (material.metallic < 1.0f && material.transmission < 1.0f);
}

// Per lobe: BSDF * n_dot_l = throughput * PDF_lobe, light sample of PDF pdf
// w_balance = pdf / (pdf + PDF_lobe)
// => BSDF * n_dot_l / pdf * w_balance = throughput * PDF_lobe / (PDF_lobe + pdf)
// w_power = pdf^2 / (pdf^2 + PDF_lobe^2)
// => BSDF * n_dot_l / pdf * w_power = throughput * PDF_lobe / (pdf * (1 + (PDF_lobe / pdf)^2))
[CudaDeviceExport] public func neeBSDF(in_dir: float3, dir: float3, n: float3, material: Material, eta_i: float, eta_o: float, refracted: bool, pdf: float, power: bool, random_state: uint) -> float3 {
    var f: float3 = float3(0.0f);
    for (var lobe: uint = 0u; lobe < 3u; lobe++) {
        if ((lobe == LOBE_REFRACT) == refracted) {
            let l: SampleBSDF = connectBSDF(in_dir, dir, n, material, eta_i, eta_o, lobe, random_state);
            if (l.pdf > 0.0f) {
                if (power) {
                    let ratio: float = l.pdf / pdf;
                    f += l.throughput * l.pdf / (pdf * (1.0f + ratio * ratio));
                } else {
                    f += l.throughput * l.pdf / (l.pdf + pdf);
                }
            }
        }
    }
    return f;
}

// eta_i = eta_o => F = 0, l = -v
// => throughput = transmission * (1 - metallic) * G1_l * albedo
[CudaDeviceExport] public func straightThrough(dir: float3, n: float3, material: Material) -> float3 {
    let F_greyscale: float = rgb_to_greyscale(material.albedo * material.metallic);
    return material.transmission * smithG1(material.roughness * material.roughness, abs(dot(n, dir))) * (1.0f - F_greyscale) * material.albedo;
}


// Shadow end lifted off the emitter by its geometry offset, toward start
[CudaDeviceExport] public func shadowLift(light_n: float3, light_offset: float, start: float3, end: float3) -> float3 {
    return light_n * (sign(dot(light_n, start - end)) * light_offset);
}

// A relative 1e-4 short of the end
[CudaDeviceExport] public func shadowLength(shadow: float3) -> float {
    return length(shadow) * (1.0f - 1e-4f);
}

// Covered share straight through at IOR 1, else blocked; the uncovered rest passes
[CudaDeviceExport] public func occluderTransmittance(toward: float3, n: float3, material: Material, coverage: float) -> float3 {
    let through: float3 = material.ior == 1.0f ? straightThrough(toward, n, material) : float3(0.0f);
    return through * coverage + (1.0f - coverage);
}

public static const uint LOBE_DIFFUSE = 0u;
public static const uint LOBE_REFRACT = 1u;

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
static const float RESTIR_CAP = 20.0;
static const float RESTIR_CAP_MIN = 1.0;
static const float RESTIR_DUPLICATION_ALPHA = 0.1;

[CudaDeviceExport] public func facingSign(transmission: float, face: float3, direction: float3) -> float {
    return transmission > 0.0f || dot(face, direction) < 0.0f ? 1.0f : -1.0f;
}

[CudaDeviceExport] public func geometryDensity(geometry_n: float3, direction: float3, distance: float) -> float {
    return abs(dot(geometry_n, direction)) / (distance * distance);
}

[CudaDeviceExport] public func footprintThreshold(geometry_density: float) -> float {
    return RESTIR_FOOTPRINT / geometry_density;
}

[CudaDeviceExport] public func withinFootprint(open: bool, prev_rough: bool, prev_pdf: float, geometry_density: float, threshold: float) -> bool {
    return open && prev_rough && prev_pdf * geometry_density * threshold <= 1.0f;
}

[CudaDeviceExport] public func withinInverseFootprint(pdf: float, diffuse: bool, prev_cos: float, distance: float, threshold: float) -> bool {
    return pdf > 0.0f && (diffuse || pdf * prev_cos / (distance * distance) * threshold <= 1.0f);
}

[CudaDeviceExport] public func roughLobe(pdf: float, diffuse: bool, roughness: float) -> bool {
    return pdf > 0.0f && (diffuse || roughness >= RESTIR_ROUGHNESS);
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

[CudaDeviceExport] public func confidenceCap(duplicated: float) -> float {
    return interpolate(RESTIR_CAP, RESTIR_CAP_MIN, pow(duplicated, RESTIR_DUPLICATION_ALPHA));
}
float interpolate(float a, float b, float t) {
    __target_switch {
    case wgsl: __intrinsic_asm "mix($0, $1, $2)";
    default: return a + (b - a) * t;
    }
}

[CudaDeviceExport] public func temporalWeights(c: float, p_c: float, c_t: float, p_t: float, g_previous: float, g_current: float) -> float2 {
    return float2(c * p_c / (c * p_c + c_t * g_previous), c_t * p_t / (c_t * p_t + c * g_current));
}

[CudaDeviceExport] public func pairShare(c_n: float, c_pair: float, c_sum: float) -> float {
    return (c_n + c_pair) / c_sum;
}

[CudaDeviceExport] public func neighborWeight(share: float, c_n: float, p_n: float, c_pair: float, g_here: float) -> float {
    return share * c_n * p_n / (c_n * p_n + c_pair * g_here);
}

[CudaDeviceExport] public func canonicalWeight(share: float, c_pair: float, p_c: float, c_n: float, g_there: float) -> float {
    return share * c_pair * p_c / (c_pair * p_c + c_n * g_there);
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
[CudaDeviceExport] public func sinSubClamped(sin_a: float, cos_a: float, sin_b: float, cos_b: float) -> float {
    return select(sin_a * cos_b - cos_a * sin_b, 0.0f, cos_a > cos_b);
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
    let sin_theta_x: float = sinSubClamped(sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
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
