// The BSDF functions as a single call takes them, their material and view values precomputed for that call
using TermsV = Vector<float, 3>;
static SampleBSDF sampleBSDF(TermsV in_dir, TermsV n, Material m, float eta_i, float eta_o, uint32_t random_init,
    Vector<float, 2> screen_space) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    return sampleBSDF(in_dir, n, m, eta_i, eta_o, random_init, screen_space, terms,
        precomputeView(in_dir, n, m, terms, random_init));
}
static SampleBSDF lobeBSDF(TermsV in_dir, TermsV out_dir, TermsV n, Material m, float eta_i, float eta_o, uint32_t lobe,
    uint32_t random_init) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    return lobeBSDF(in_dir, out_dir, n, m, eta_i, eta_o, lobe, random_init, terms,
        precomputeView(in_dir, n, m, terms, random_init));
}
static TermsV BSDF(TermsV in_dir, TermsV out_dir, TermsV n, TermsV g_n, Material m, float eta_i, float eta_o,
    uint32_t random_state) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    return BSDF(in_dir, out_dir, n, g_n, m, eta_i, eta_o, random_state, terms,
        precomputeView(in_dir, n, m, terms, random_state));
}
static TermsV neeBSDF(TermsV in_dir, TermsV dir, TermsV n, Material m, float eta_i, float eta_o, bool refracted,
    float pdf, bool power, uint32_t random_state) {
    const MaterialTerms terms = precomputeMaterial(m, eta_i, eta_o);
    return neeBSDF(in_dir, dir, n, m, eta_i, eta_o, refracted, pdf, power, random_state, terms,
        precomputeView(in_dir, n, m, terms, random_state));
}
