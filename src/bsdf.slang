// BSDF of renderer.cu in flex-cuda-pt, matched to Blender Cycles
module bsdf;

import math;
import random;

static const uint LOBE_DIFFUSE = 0u;
static const uint LOBE_REFRACT = 1u;
static const uint LOBE_REFLECT = 2u;

// What a material's program leaves on the stack, from the bottom
__extern_cpp public struct Surface {
    __extern_cpp public float3 normal;
    __extern_cpp public float3 albedo;
    __extern_cpp public float metallic;
    __extern_cpp public float roughness;
    __extern_cpp public float3 emissive;
    __extern_cpp public float transparency;
    __extern_cpp public float ior;
    __extern_cpp public float3 absorption;
    __extern_cpp public float density;
};
// Tangent space, columns; Matrix is taken by the Slang prelude
__extern_cpp public struct Frame { __extern_cpp public float3 x; __extern_cpp public float3 y; __extern_cpp public float3 z; };

// Exact Smith masking of GGX, the visible normal density sampleGGXVNDF draws from
float smithG1(float alpha, float n_dot_x) {
    const float alpha_sq = alpha * alpha;
    return 2.0f * n_dot_x / (n_dot_x + sqrt(alpha_sq + (1.0f - alpha_sq) * n_dot_x * n_dot_x));
}

float trowbridgeReitz(float alpha, float n_dot_h) {
    const float numerator = alpha * alpha;
    const float denom = n_dot_h * n_dot_h * (numerator - 1.0f) + 1.0f;
    return numerator / max(PI * denom * denom, BIAS);
}

float G1(float alpha, float n_dot_x) {
    const float k = alpha * 0.5f;
    return n_dot_x / max(n_dot_x * (1.0f - k) + k, BIAS);
}

float schlickBeckmann(float k, float n_dot_x) {
    return n_dot_x / max(n_dot_x * (1.0f - k) + k, BIAS);
}

float smith(float alpha, float n_dot_v, float n_dot_l) {
    const float k = alpha * 0.5f;
    return schlickBeckmann(k, n_dot_v) * schlickBeckmann(k, n_dot_l);
}

float fresnel(float cos_theta, float eta_i, float eta_o) {
    // Compute sini using Snell's law
    const float sin_theta = sqrt(max(0.0f, 1.0f - cos_theta * cos_theta));
    const float sin_psi = (eta_i / eta_o) * sin_theta;
    // Total internal reflection
    float kr = 1.0f;
    if (sin_psi < 1.0f) {
        const float cos_psi = sqrt(max(0.0f, 1.0f - sin_psi * sin_psi));
        const float Rs = ((eta_o * cos_theta) - (eta_i * cos_psi)) / ((eta_o * cos_theta) + (eta_i * cos_psi));
        const float Rp = ((eta_i * cos_theta) - (eta_o * cos_psi)) / ((eta_i * cos_theta) + (eta_o * cos_psi));
        kr = (Rs * Rs + Rp * Rp) / 2.0f;
    }
    return kr;
}

// Sampling of the GGX VNDF
float3 sampleGGXVNDF(float3 Ve, float alpha, float U1, float U2) {
    // The Ve argument is the view direction in tangent space, where the normal is (0, 0, 1).
    // Section 3.2: transforming the view direction to the hemisphere configuration.
    const float3 Vh = normalize(float3(alpha * Ve.x, alpha * Ve.y, Ve.z));
    // Section 4.1: orthonormal basis (with special case if cross product is zero).
    const float lensq = Vh.x * Vh.x + Vh.y * Vh.y;
    const float3 T1 = lensq > 0.0f ? float3(-Vh.y, Vh.x, 0.0f) * rsqrt(lensq) : float3(1.0f, 0.0f, 0.0f);
    const float3 T2 = cross(Vh, T1);
    // Section 4.2: parameterization of the projected area.
    const float r = sqrt(U1);
    const float phi = 2.0f * PI * U2;
    const float t1 = r * cos(phi);
    float t2 = r * sin(phi);
    const float s = 0.5f * (1.0f + Vh.z);
    t2 = (1.0f - s) * sqrt(max(0.0f, 1.0f - t1 * t1)) + s * t2;
    // Section 4.3: reprojection onto hemisphere.
    const float3 Nh = t1 * T1 + t2 * T2 + sqrt(max(0.0f, 1.0f - t1 * t1 - t2 * t2)) * Vh;
    // Section 3.4: transforming the normal back to the ellipsoid configuration.
    return normalize(float3(alpha * Nh.x, alpha * Nh.y, max(0.0f, Nh.z)));
}

// Corresponding PDF is: pdf = cos(theta) / PI
float3 sampleCosWeightedHemisphere(float random_1, float random_2) {
    const float r = sqrt(random_1);
    const float theta = 2.0f * PI * random_2;
    const float x = r * cos(theta);
    const float z = r * sin(theta);
    const float y = sqrt(max(0.0f, 1.0f - x * x - z * z));
    return float3(x, y, z);
}

float3 tangentToWorld(float3 v, float3 n) {
    float3 a = float3(0.0f, 1.0f, 0.0f);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0f, 0.0f, 0.0f);
    }
    const float3 tangent = normalize(cross(n, a));
    const float3 bitangent = cross(n, tangent);
    return v.x * tangent + v.y * n + v.z * bitangent;
}

float3 worldToTangent(float3 v, float3 n) {
    float3 a = float3(0.0f, 1.0f, 0.0f);
    if (abs(dot(n, a)) > 1.0f - BIAS) {
        a = float3(1.0f, 0.0f, 0.0f);
    }
    const float3 tangent = normalize(cross(n, a));
    const float3 bitangent = cross(n, tangent);
    return float3(dot(v, tangent), dot(v, n), dot(v, bitangent));
}

// Build TBN matrix for tangent-space normal mapping. Uses triangle edges and UV deltas to compute
// tangent (U direction) and bitangent (V direction), with handedness fix.
[CudaDeviceExport]
public Frame normalMapTBN(float3 p0, float3 p1, float3 p2, float2 uv0, float2 uv1, float2 uv2, float3 n) {
    const float3 e1 = p1 - p0;
    const float3 e2 = p2 - p0;
    const float2 duv1 = uv1 - uv0;
    const float2 duv2 = uv2 - uv0;
    // Compute inverse determinant for UV to world space transformation.
    const float det = duv1.x * duv2.y - duv1.y * duv2.x;
    const float inv_det = 1.0f / det;
    float3 t = (e1 * duv2.y - e2 * duv1.y) * inv_det;
    const float3 b_geom = (e2 * duv1.x - e1 * duv2.x) * inv_det;
    // Gram-Schmidt: make tangent perpendicular to interpolated normal.
    t = normalize(t - n * dot(n, t));
    // Handedness: bitangent along the geometric b, mirrored with the UVs, as Blender's tangent space.
    const float3 b = cross(n, t) * sign(dot(cross(n, t), b_geom));
    return { t, b, n };
}

[CudaDeviceExport]
public float3 tangentToWorldNormalMap(float3 v, Frame tbn) { return tbn.x * v.x + tbn.y * v.y + tbn.z * v.z; }

// BSDF takes in incoming and outgoing directions and surface properties returning throughput for direct lighting
// Only consider lighting on the surface of the object, not the inside. Assume direct light is always outside the object
// as shadowing also makes that assumption.
[CudaDeviceExport]
public float3 BSDF(float3 in_dir, float3 out_dir, float3 n, float3 g_n, Surface material, float eta_i, float eta_o) {
    const float3 v = - in_dir;
    // Precalculate dot products
    const float n_dot_v = dot(n, v);
    const float n_dot_l = dot(n, out_dir);
    // Calculate material constants needed for BRDF and BTDF
    const float alpha = material.roughness * material.roughness;
    // Precalculate dot products for geometry normal
    const float g_n_dot_v = dot(g_n, v);
    const float g_n_dot_l = dot(g_n, out_dir);
    // Test if v and l are on the same side of the surface
    if (g_n_dot_v * g_n_dot_l > 0.0f) {
        // If v and l are on the same side of the surface do Torrance-Sparrow BRDF
        // Positive definite dot products
        const float pd_n_dot_v = max(n_dot_v, 0.0f);
        const float pd_n_dot_l = max(n_dot_l, 0.0f);
        // Precaluclate dot products and half vectors
        const float3 h_r = normalize(out_dir + v);
        const float v_dot_h = max(dot(v, h_r), 0.0f);
        const float n_dot_h = max(dot(n, h_r), 0.0f);
        // Lambertian diffuse
        const float3 lambert = material.albedo * INV_PI;
        // Torrance-Sparrow
        const float3 F = mix(float3(1.0f) * fresnel(abs(v_dot_h), eta_i, eta_o), material.albedo, material.metallic);
        const float F_greyscale = rgb_to_greyscale(F);
        const float D = trowbridgeReitz(alpha, n_dot_h);
        const float G = smith(alpha, pd_n_dot_v, pd_n_dot_l);
        const float diffuse_factor = (1.0f - F_greyscale) * (1.0f - material.metallic) * (1.0f - material.transparency);
        const float3 torrance_sparrow = D * F * G / max(4.0f * pd_n_dot_v * pd_n_dot_l, BIAS);
        const float3 radiance = diffuse_factor * lambert + torrance_sparrow;
        return radiance * n_dot_l;
    } else {
        // Refractive half-vector (eq. 16)
        const float3 ht_unorm = - (eta_i * v + eta_o * out_dir);
        const float3 ht = normalize(ht_unorm);
        // Precalculate dot products
        const float v_dot_ht = dot(v, ht);
        const float l_dot_ht = dot(out_dir, ht);
        const float n_dot_ht = abs(dot(n, ht));
        // Microfacet terms
        const float DT = trowbridgeReitz(alpha, abs(n_dot_ht));
        const float GT = smith(alpha, abs(n_dot_v), abs(n_dot_l));
        const float3 FT = mix(float3(1.0f) * fresnel(abs(v_dot_ht), eta_i, eta_o), material.albedo, material.metallic);
        // Geometry term numerator and denominator
        const float numerator_geom = abs(v_dot_ht) * abs(l_dot_ht);
        const float denominator_geom = abs(n_dot_v) * abs(n_dot_l);
        // Refractive term denominator
        const float denom_f = eta_i * v_dot_ht + eta_o * l_dot_ht;
        const float denom_f_sq = denom_f * denom_f;
        // Check if refraction is possible
        if (abs(denom_f) > BIAS && denominator_geom > BIAS) {
            // Term is colored by albedo as the surface, the medium's absorption is Beer's law's
            const float walter = (numerator_geom / denominator_geom) * (1.0f - rgb_to_greyscale(FT)) * DT * GT
                * (eta_o * eta_o / denom_f_sq);
            return material.albedo * (walter * material.transparency * n_dot_l);
        }
        // If refraction is not possible, return black this case should never happen
        return float3(0.0f, 0.0f, 0.0f);
    }
}

__extern_cpp public struct SampleBSDF {
    __extern_cpp public float3 unit_direction;
    __extern_cpp public float3 throughput;
    __extern_cpp public uint random_state;
    __extern_cpp public bool refracted;
    __extern_cpp public uint lobe;
    // Solid angle density of the sampled direction as evalLobe defines it, zero for delta lobes
    __extern_cpp public float pdf;
};

// SampleBSDF takes in incoming direction, surface normal, material and random state and returns an outgoing direction
// with throughput according to the BSDF for global illumination
[CudaDeviceExport]
public SampleBSDF sampleBSDF(float3 in_dir, float3 n, Surface material, float eta_i, float eta_o, uint random_init) {
    uint random_state = random_init;
    // Basic dot products
    const float3 v = - in_dir;
    const float n_dot_v = dot(n, v);
    const float3 n_i = n * sign(n_dot_v);
    const float n_i_dot_v = abs(n_dot_v);
    // Material constants
    const float alpha = material.roughness * material.roughness;
    // Generate random values for sampling
    const Random random_h_1 = pcg(random_state);
    const Random random_h_2 = pcg(random_h_1.state);
    random_state = random_h_2.state;
    // Sample using GGX importance sampling for potential refractive or reflective case, back in world space
    const float3 v_tangent = worldToTangent(v, n_i);
    const float3 ggx_n = tangentToWorld(sampleGGXVNDF(v_tangent.xzy, alpha, random_h_1.value, random_h_2.value).xzy, n_i);
    // Calculate shared half vector dot products
    const float v_dot_h = dot(ggx_n, v);
    const float n_dot_h = dot(n_i, ggx_n);
    // Visible normal density of the unclamped GGX distribution for the sampled half vector
    const float d_term = n_dot_h * n_dot_h * (alpha * alpha - 1.0f) + 1.0f;
    const float pdf_h = alpha > 0.0f && v_dot_h > 0.0f && n_dot_h > 0.0f && n_i_dot_v > 0.0f
        ? smithG1(alpha, n_i_dot_v) * v_dot_h * alpha * alpha / (PI * d_term * d_term * n_i_dot_v) : 0.0f;
    // Try refraction through the properly oriented half vector
    const float eta = eta_i / eta_o;
    const float3 refracted = normalize(refract(in_dir, ggx_n, eta));
    // Calculate fresnel term
    const float3 F = mix(float3(1.0f) * fresnel(abs(v_dot_h), eta_i, eta_o), material.albedo, material.metallic);
    const float F_greyscale = rgb_to_greyscale(F);
    // BSDF weights (these are artistic choices to balance the lobes)
    const float reflect_weight = 1.0f;
    const float diffuse_weight = (1.0f - material.transparency) * (1.0f - material.metallic);
    const float refract_weight = material.transparency;
    // Add fresnel term for improved sampling performance
    const float reflect_component = max(reflect_weight * F_greyscale, 0.0f);
    const float diffuse_component = max(diffuse_weight * (1.0f - F_greyscale), 0.0f);
    const float refract_component = max(refract_weight * (1.0f - F_greyscale)
        * sign(sqrt(dot(refracted, refracted))), 0.0f);
    // Calculate sampling probabilities
    const float total_component = reflect_component + diffuse_component + refract_component;
    const float total_component_inv = 1.0f / max(total_component, BIAS);
    const float p_diffuse = diffuse_component * total_component_inv;
    const float p_reflect = reflect_component * total_component_inv;
    const float p_refract = refract_component * total_component_inv;

    SampleBSDF sampled = { float3(1.0f), float3(1.0f), 0u, false, LOBE_DIFFUSE, 0.0f };
    const Random random_p = pcg(random_state);
    random_state = random_p.state;
    // Diffuse case
    if (random_p.value < p_diffuse) {
        const Random random_d_1 = pcg(random_state);
        const Random random_d_2 = pcg(random_d_1.state);
        sampled.random_state = random_d_2.state;
        // Sample cosine weighted hemisphere
        const float3 cosine_hemisphere = sampleCosWeightedHemisphere(random_d_1.value, random_d_2.value);
        sampled.unit_direction = tangentToWorld(cosine_hemisphere, n_i);

        // BSDF = diffuse_weight * albedo / PI
        // => BSDF * n_dot_v = diffuse_weight * albedo * n_dot_l / PI

        // PDF_COSINE_HEMISPHERE = cosine_hemisphere.y / PI
        // => PDF = cosine_hemisphere.y / PI

        // throughput = BSDF * n_dot_l / PDF
        //            = diffuse_weight * albedo * n_dot_l / PI / cosine_hemisphere.y * PI
        //            = diffuse_weight * albedo * n_dot_l / cosine_hemisphere.y

        // Since cosine_hemisphere.y is n_dot_l over the unit hemisphere, we can simplify the throughput to:
        // => throughput = albedo * diffuse_weight
        sampled.throughput = diffuse_weight * material.albedo / p_diffuse;
        sampled.pdf = n_i_dot_v > 0.0f ? p_diffuse * cosine_hemisphere.y * INV_PI : 0.0f;
        return sampled;
    }
    // Refractive case
    if (random_p.value < p_diffuse + p_refract) {
        // Refraction is valid
        sampled.unit_direction = refracted;
        const float3 l = sampled.unit_direction;
        const float m_n_i_dot_l = - dot(n_i, l);
        const float l_dot_h = dot(l, ggx_n);
        const float denom = eta_i * v_dot_h + eta_o * l_dot_h;
        sampled.pdf = eta_i != eta_o && l_dot_h < 0.0f
            ? p_refract * pdf_h * eta_o * eta_o * abs(l_dot_h) / (denom * denom) : 0.0f;
        // Microfacet term
        const float G1_l = G1(alpha, max(m_n_i_dot_l, 0.0f));
        // JACOBIAN = eta_o^2 * l_dot_h / (eta_i * v_dot_h + eta_o * l_dot_h)^2

        // BSDF = refract_weight * v_dot_h / n_dot_v / n_dot_l * D * G * (1 - F) * JACOBIAN
        // => BSDF * n_dot_l = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN

        // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
        // PDF_REFRACT = PDF_VNDF * JACOBIAN
        //             = G1_v * v_dot_h * D / n_dot_v * JACOBIAN

        // PDF = PDF_REFRACT
        //     = G1_v * v_dot_h * D / n_dot_v * JACOBIAN

        // throughput = BSDF * n_dot_l
        //            = refract_weight * v_dot_h / n_dot_v * D * G * (1 - F) * JACOBIAN / G1_v / v_dot_h / D * n_dot_v / JACOBIAN
        //            = refract_weight * G * (1 - F) / G1_v

        // G = G1_v * G1_l
        // => throughput = refract_weight * G1_l * (1 - F)
        sampled.throughput = material.albedo * (refract_weight * G1_l * (1.0f - F_greyscale) / p_refract);
        sampled.random_state = random_state;
        sampled.refracted = true;
        sampled.lobe = LOBE_REFRACT;
        return sampled;
    }
    // Otherwise assume reflective case.
    sampled.unit_direction = normalize(reflect(in_dir, ggx_n));
    const float3 l = sampled.unit_direction;
    const float n_i_dot_l = dot(n_i, l);
    // Torrance-Sparrow
    const float G1_l = G1(alpha, max(n_i_dot_l, 0.0f));
    // BSDF = reflect_weight * D * G * F / (4 * n_dot_v * n_dot_l)
    // => BSDF * n_dot_l = reflect_weight * D * G * F / (4 * n_dot_v)

    // PDF_VNDF = G1_v * v_dot_h * D / n_dot_v
    // JACOBIAN = 1 / (4 * v_dot_h)
    // PDF_REFLECT = PDF_VNDF * JACOBIAN
    // => PDF_REFLECT = G1_v * D / (4 * n_dot_v)

    // PDF = PDF_REFLECT
    // => PDF = G1_v * D / (4 * v_dot_n)

    // throughput = BSDF * n_dot_l / PDF
    //            = reflect_weight * D * G * F / (4 * n_dot_v) / G1_v / D * (4 * n_dot_v)
    //            = reflect_weight * G * F / G1_v

    // G = G1_v * G1_l
    // => throughput = reflect_weight * G1_l * F
    sampled.throughput = reflect_weight * G1_l * F / p_reflect;
    sampled.random_state = random_state;
    sampled.lobe = LOBE_REFLECT;
    sampled.pdf = pdf_h > 0.0f ? p_reflect * pdf_h / (4.0f * v_dot_h) : 0.0f;
    return sampled;
}

[CudaDeviceExport]
public bool neeDecision(Surface material, float n_dot_v, float eta_i, float eta_o) {
    // Calculate fresnel term
    const float3 F_n = mix(float3(1.0f) * fresnel(abs(n_dot_v), eta_i, eta_o), material.albedo, material.metallic);
    const float F_n_greyscale = rgb_to_greyscale(F_n);
    const float diffuse_factor_estimate = max((1.0f - F_n_greyscale) * (1.0f - material.metallic)
        * (1.0f - material.transparency), 0.0f);
    return diffuse_factor_estimate > 0.04f || material.roughness > 0.2f;
}

__extern_cpp public struct Lobe {
    __extern_cpp public float3 f_cos;
    __extern_cpp public float pdf;
};

// BSDF times cosine and solid angle density of sampleBSDF choosing lobe and producing out_dir.
// Both are the ones sampleBSDF's throughput implies, delta lobes have no density and evaluate to zero.
[CudaDeviceExport]
public Lobe evalLobe(float3 in_dir, float3 out_dir, float3 n, Surface material, float eta_i, float eta_o, uint lobe,
    uint random_state) {
    const Lobe none = { float3(0.0f, 0.0f, 0.0f), 0.0f };
    const float3 v = - in_dir;
    const float3 n_i = n * sign(dot(n, v));
    const float n_i_dot_v = abs(dot(n, v));
    const float alpha = material.roughness * material.roughness;
    float3 h = normalize(v + out_dir);
    if (lobe == LOBE_DIFFUSE) {
        // The visible normal only steers the lobe choice of diffuse samples
        const Random random_h_1 = pcg(random_state);
        const Random random_h_2 = pcg(random_h_1.state);
        h = tangentToWorld(sampleGGXVNDF(worldToTangent(v, n_i).xzy, alpha, random_h_1.value, random_h_2.value).xzy,
            n_i);
    } else if (lobe == LOBE_REFRACT) {
        // Refraction without index change passes straight through
        if (eta_i == eta_o) {
            return none;
        }
        const float3 h_t = - (eta_i * v + eta_o * out_dir);
        h = normalize(h_t) * sign(dot(h_t, n_i));
    }
    const float v_dot_h = dot(v, h);
    const float l_dot_h = dot(out_dir, h);
    const float n_dot_l = dot(n_i, out_dir);
    const float n_dot_h = dot(n_i, h);
    const float3 F = mix(float3(1.0f) * fresnel(abs(v_dot_h), eta_i, eta_o), material.albedo, material.metallic);
    const float F_greyscale = rgb_to_greyscale(F);
    const float eta = eta_i / eta_o;
    const float refractable = 1.0f - eta * eta * (1.0f - v_dot_h * v_dot_h) >= 0.0f ? 1.0f : 0.0f;
    const float diffuse_weight = (1.0f - material.transparency) * (1.0f - material.metallic);
    // Lobe probabilities as sampleBSDF uses them and the chance its random number lands in each lobe
    const float components[3] = { max(diffuse_weight * (1.0f - F_greyscale), 0.0f),
        max(material.transparency * (1.0f - F_greyscale) * refractable, 0.0f), max(F_greyscale, 0.0f) };
    const float total = max(components[0] + components[1] + components[2], BIAS);
    const float p[3] = { components[0] / total, components[1] / total, components[2] / total };
    const float cdf[2] = { min(p[0], 1.0f), min(p[0] + p[1], 1.0f) };
    const float chance[3] = { cdf[0], cdf[1] - cdf[0], 1.0f - cdf[1] };
    if (chance[lobe] <= 0.0f || p[lobe] <= 0.0f || n_i_dot_v <= 0.0f) {
        return none;
    }
    if (lobe == LOBE_DIFFUSE) {
        const float pdf = chance[0] * max(n_dot_l, 0.0f) * INV_PI;
        return { pdf * diffuse_weight * material.albedo / p[0], pdf };
    }
    if (alpha == 0.0f || v_dot_h <= 0.0f || n_dot_h <= 0.0f) {
        return none;
    }
    // Visible normal density of the unclamped GGX distribution
    const float d_term = n_dot_h * n_dot_h * (alpha * alpha - 1.0f) + 1.0f;
    const float pdf_h = smithG1(alpha, n_i_dot_v) * v_dot_h * alpha * alpha / (PI * d_term * d_term * n_i_dot_v);
    if (lobe == LOBE_REFRACT) {
        if (l_dot_h >= 0.0f) {
            return none;
        }
        const float denom = eta_i * v_dot_h + eta_o * l_dot_h;
        const float pdf = chance[1] * pdf_h * eta_o * eta_o * abs(l_dot_h) / (denom * denom);
        return { material.albedo
            * (pdf * material.transparency * G1(alpha, max(- n_dot_l, 0.0f)) * (1.0f - F_greyscale) / p[1]), pdf };
    }
    const float pdf = chance[2] * pdf_h / (4.0f * v_dot_h);
    return { pdf * G1(alpha, max(n_dot_l, 0.0f)) * F / p[2], pdf };
}
