// The BSDF functions as a single call takes them, their material and view values precomputed for that call
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
TERMS SampleBSDF sampleBSDF(TermsV in_dir, TermsV n, TermsM m, float eta_i, float eta_o, unsigned random_init,
    TermsV2 screen_space) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    return sampleBSDF(in_dir, n, m, eta_i, eta_o, random_init, screen_space, terms,
        precomputeView(in_dir, n, m, terms));
}
// sampleBSDF's lobe toward a given out_dir by its half vector terms and its BSDF and PDF functions, as the walk's
// replay takes it: diffuse 0, refract 1, reflect 2, sheen 4, toon 6, directions it can't sample carrying nothing
TERMS SampleBSDF towardLobe(TermsV in_dir, TermsV out_dir, TermsV n, TermsM m, float eta_i, float eta_o,
    unsigned lobe, unsigned random_init) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    const ViewTerms view_terms = precomputeView(in_dir, n, m, terms);
    const float n_dot_v = dot_0(n, negate_0(in_dir)), alpha = m.roughness * m.roughness;
    const TermsV n_i = n * TermsV(sign_0(n_dot_v));
    const float n_i_dot_l = dot_0(n_i, out_dir), n_i_dot_v = fabsf(n_dot_v);
    float pdf, l_dot_h = 0;
    TermsV throughput;
    if (lobe == 0) {
        const HalfTerms h = precomputeHalf(in_dir, sampledHalf(in_dir, n, m, random_init, view_terms), m, eta_i, eta_o,
            terms, view_terms);
        pdf = diffusePDF(n_i_dot_l, 0, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = diffuseBSDF(out_dir, n_i, alpha, m, h);
    } else if (lobe == 1) {
        const TermsV h_t = refractedHalf(in_dir, out_dir, n, eta_i, eta_o);
        l_dot_h = dot_0(out_dir, h_t);
        const HalfTerms h = precomputeHalf(in_dir, h_t, m, eta_i, eta_o, terms, view_terms);
        pdf = refractPDF(n_i_dot_l, l_dot_h, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = refractBSDF(out_dir, n_i, alpha, m, h);
    } else if (lobe == 4) {
        const HalfTerms h = precomputeHalf(in_dir, reflectedHalf(in_dir, out_dir), m, eta_i, eta_o, terms, view_terms);
        pdf = sheenVelvetPDF(n_i_dot_l, 0, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = sheenVelvetBSDF(out_dir, n_i, alpha, m, h);
#ifndef FK_UNTOON
    } else if (lobe == 6) {
        const HalfTerms h = precomputeHalf(in_dir, sampledHalf(in_dir, n, m, random_init, view_terms), m, eta_i, eta_o,
            terms, view_terms);
        pdf = toonPDF(n_i_dot_l, dot_0(out_dir, h.toon_axis), n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = toonBSDF(out_dir, n_i, alpha, m, h);
#endif
    } else {
        const HalfTerms h = precomputeHalf(in_dir, reflectedHalf(in_dir, out_dir), m, eta_i, eta_o, terms, view_terms);
        pdf = reflectPDF(n_i_dot_l, 0, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = reflectBSDF(out_dir, n_i, alpha, m, h);
    }
    if (!(pdf > 0)) return SampleBSDF{};
    return SampleBSDF{out_dir, throughput, random_init, lobe == 1, lobe, pdf};
}
TERMS TermsV BSDF(TermsV in_dir, TermsV out_dir, TermsV n, TermsV g_n, TermsM m, float eta_i, float eta_o,
    unsigned random_state) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    return BSDF(in_dir, out_dir, n, g_n, m, eta_i, eta_o, random_state, terms, precomputeView(in_dir, n, m, terms));
}
TERMS TermsV neeBSDF(TermsV in_dir, TermsV dir, TermsV n, TermsM m, float eta_i, float eta_o, bool refracted,
    float pdf, bool power, unsigned random_state) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    return neeBSDF(in_dir, dir, n, m, eta_i, eta_o, refracted, pdf, power, random_state, terms,
        precomputeView(in_dir, n, m, terms));
}
