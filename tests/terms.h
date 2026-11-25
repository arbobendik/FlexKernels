// sampleBSDF's density and BSDF toward a given out_dir, as the walk's replay takes them
#ifdef __CUDACC__
#define TERMS __device__ static
using TermsV = float3;
using TermsV2 = float2;
using TermsM = BSDFMaterial;
#else
#define TERMS static
using TermsV = Vector<float, 3>;
using TermsV2 = Vector<float, 2>;
using TermsM = Material;
#endif
TERMS SampleBSDF towardLobe(TermsV in_dir, TermsV out_dir, TermsV n, TermsM m, float eta_i, float eta_o,
    unsigned lobe, unsigned random_init) {
    const float n_dot_v = dot_0(n, negate_0(in_dir));
    const bool refracted = lobe == 1 || (lobe == 0 && translucentShare(m) > 0 && dot_0(n, out_dir) * n_dot_v < 0);
    float pdf = 0;
    const TermsV f = BSDF(in_dir, out_dir, n, m, eta_i, eta_o, refracted, random_init,
        64u | 1u << (lobe == 4 ? 3 : lobe == 6 ? 4 : lobe), &pdf);
    if (!(pdf > 0)) return SampleBSDF{};
    return SampleBSDF{out_dir, f, random_init, refracted, lobe, pdf};
}

// BSDF toward out_dir, across the face where in_dir and out_dir lie on opposite sides of g_n
TERMS TermsV faceBSDF(TermsV in_dir, TermsV out_dir, TermsV n, TermsV g_n, TermsM m, float eta_i, float eta_o,
    unsigned random_state) {
    float pdf = 0;
    return BSDF(in_dir, out_dir, n, m, eta_i, eta_o, dot_0(g_n, negate_0(in_dir)) * dot_0(g_n, out_dir) <= 0,
        random_state, 63u, &pdf);
}
