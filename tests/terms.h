// sampleBSDF's lobe toward a given out_dir by its half vector's weights and its BSDF and PDF functions, as the walk's
// replay takes it: diffuse 0, refract 1, reflect 2, sheen 4, coat 5, toon 6, directions it can't sample carrying
// nothing
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
    const TermsV v = negate_0(in_dir);
    const float n_dot_v = dot_0(n, v), alpha = m.roughness * m.roughness;
    const TermsV n_i = n * TermsV(sign_0(n_dot_v));
    const float n_i_dot_l = dot_0(n_i, out_dir), n_i_dot_v = fabsf(n_dot_v);
    const AnisotropicFrame frame = anisotropicFrame(m, n_i);
    const SheenProfile sheen_profile = sheenProfile(v, n_i, m);
    const CoatFrame coat_frame = coatFrame(m, n_i);
    const TermsV coat_series = coatSeries(coat_frame, m);
    TermsV h = reflectedHalf(in_dir, out_dir);
    if (lobe == 1) h = refractedHalf(in_dir, out_dir, n, eta_i, eta_o);
    // The coat lobe's microfacet the reflective one over sampleBSDF's, the base lobes' sampleBSDF's coat's
    const TermsV coat_h = lobe == 5 ? h : coatHalf(v, coat_frame, random_init);
    if (lobe == 0 || lobe == 5 || lobe == 6) h = sampledHalf(v, n_i, alpha, frame, random_init);
    const Weights w = lobeWeights(in_dir, v, n_i, h, coat_h, frame, sheen_profile, coat_frame, coat_series, m,
        eta_i, eta_o);
    float pdf;
    TermsV throughput;
    if (lobe == 0) {
        pdf = diffusePDF(n_i_dot_l, n_i_dot_v, m, w);
        throughput = diffuseBSDF(out_dir, n_i, m, w);
    } else if (lobe == 1) {
        pdf = refractPDF(dot_0(out_dir, h), vndfPDF(v, h, n_i, n_i_dot_v, alpha, frame, w.v_dot_h), w, eta_i, eta_o);
        throughput = refractBSDF(out_dir, n_i, alpha, frame, m, w);
    } else if (lobe == 5) {
        pdf = coatPDF(v, coat_h, coat_frame, w);
        throughput = coatBSDF(w);
    } else if (lobe == 4) {
        pdf = sheenVelvetPDF(n_i_dot_l, n_i_dot_v, w);
        throughput = sheenVelvetBSDF(out_dir, v, n_i, m, w);
#ifndef FK_UNTOON
    } else if (lobe == 6) {
        const ToonProfile profile = toonProfile(v, n_i, m);
        pdf = toonPDF(out_dir, n_i, profile, w);
        throughput = toonBSDF(out_dir, n_i, profile, w);
#endif
    } else {
        pdf = reflectPDF(vndfPDF(v, h, n_i, n_i_dot_v, alpha, frame, w.v_dot_h), w);
        throughput = reflectBSDF(out_dir, n_i, alpha, frame, w);
    }
    if (!(pdf > 0)) return SampleBSDF{};
    return SampleBSDF{out_dir, throughput, random_init, lobe == 1, lobe, pdf};
}

// BSDF toward out_dir, across the face where in_dir and out_dir lie on opposite sides of g_n
TERMS TermsV faceBSDF(TermsV in_dir, TermsV out_dir, TermsV n, TermsV g_n, TermsM m, float eta_i, float eta_o,
    unsigned random_state) {
    FixedArray<TermsV, 6> throughputs;
    FixedArray<float, 6> pdfs;
    BSDF(in_dir, out_dir, n, m, eta_i, eta_o, dot_0(g_n, negate_0(in_dir)) * dot_0(g_n, out_dir) <= 0, &throughputs,
        &pdfs);
    TermsV f = {};
    for (unsigned i = 0; i < 6; i++) {
        if (pdfs[i] > 0) f = f + throughputs[i] * TermsV(pdfs[i]);
    }
    return f;
}
