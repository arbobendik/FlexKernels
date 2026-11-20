// sampleBSDF's lobes toward a given out_dir for the tests, by their BSDF and PDF functions
using TermsV = Vector<float, 3>;
// sampleBSDF's lobe toward a given out_dir by its half vector terms and its BSDF and PDF functions, as the walk's
// replay takes it: diffuse 0, refract 1, reflect 2, sheen 4, toon 6, directions it can't sample carrying nothing
static SampleBSDF towardLobe(TermsV in_dir, TermsV out_dir, TermsV n, Material m, float eta_i, float eta_o,
    unsigned lobe, unsigned random_init) {
    const float n_dot_v = dot_0(n, negate_0(in_dir)), alpha = m.roughness * m.roughness;
    const TermsV n_i = n * TermsV(sign_0(n_dot_v));
    const AnisotropicFrame frame = anisotropicFrame(m, n_i);
    const float sheen_albedo = sheenAlbedo(negate_0(in_dir), n_i, m);
    const float n_i_dot_l = dot_0(n_i, out_dir), n_i_dot_v = fabsf(n_dot_v);
    float pdf, l_dot_h = 0;
    TermsV throughput;
    if (lobe == 0) {
        BSDFLobes h = bsdfLobes(in_dir, negate_0(in_dir), n_i, sampledHalf(in_dir, n, m, random_init, frame), m,
            eta_i, eta_o, frame, sheen_albedo);
        h.translucent_share = translucentShare(m);
        pdf = diffusePDF(n_i_dot_l, 0, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = diffuseBSDF(out_dir, n_i, alpha, m, h);
    } else if (lobe == 1) {
        const TermsV h_t = refractedHalf(in_dir, out_dir, n, eta_i, eta_o);
        l_dot_h = dot_0(out_dir, h_t);
        BSDFLobes h = bsdfLobes(in_dir, negate_0(in_dir), n_i, h_t, m, eta_i, eta_o, frame, sheen_albedo);
        h.translucent_share = translucentShare(m);
        pdf = refractPDF(n_i_dot_l, l_dot_h, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = refractBSDF(out_dir, n_i, alpha, m, h);
    } else if (lobe == 4) {
        BSDFLobes h = bsdfLobes(in_dir, negate_0(in_dir), n_i, reflectedHalf(in_dir, out_dir), m, eta_i, eta_o, frame,
            sheen_albedo);
        h.translucent_share = translucentShare(m);
        pdf = sheenVelvetPDF(n_i_dot_l, 0, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = sheenVelvetBSDF(out_dir, n_i, alpha, m, h);
#ifndef FK_UNTOON
    } else if (lobe == 6) {
        BSDFLobes h = bsdfLobes(in_dir, negate_0(in_dir), n_i, sampledHalf(in_dir, n, m, random_init, frame), m,
            eta_i, eta_o, frame, sheen_albedo);
        h.translucent_share = translucentShare(m);
        const ToonProfile profile = toonProfile(negate_0(in_dir), n_i, m);
        pdf = toonPDF(out_dir, n_i, profile, h);
        throughput = toonBSDF(out_dir, n_i, profile, h);
#endif
    } else {
        BSDFLobes h = bsdfLobes(in_dir, negate_0(in_dir), n_i, reflectedHalf(in_dir, out_dir), m, eta_i, eta_o, frame,
            sheen_albedo);
        h.translucent_share = translucentShare(m);
        pdf = reflectPDF(n_i_dot_l, 0, n_i_dot_v, alpha, h, eta_i, eta_o);
        throughput = reflectBSDF(out_dir, n_i, alpha, m, h);
    }
    if (!(pdf > 0)) return SampleBSDF{};
    return SampleBSDF{out_dir, throughput, random_init, lobe == 1, lobe, pdf};
}

// BSDF toward out_dir, across the face where in_dir and out_dir lie on opposite sides of g_n
static TermsV faceBSDF(TermsV in_dir, TermsV out_dir, TermsV n, TermsV g_n, Material m, float eta_i, float eta_o,
    unsigned random_state) {
    FixedArray<TermsV, 5> throughputs;
    FixedArray<float, 5> pdfs;
    return BSDF(in_dir, out_dir, n, m, eta_i, eta_o, dot_0(g_n, negate_0(in_dir)) * dot_0(g_n, out_dir) <= 0,
        random_state, ~0u, &throughputs, &pdfs);
}
