#include "renderer.cu"
#include <stdio.h>

static float3 unit(unsigned& state) {
    const float z = 2 * random(state) - 1, phi = 2 * PI * random(state), r = sqrtf(fmaxf(0, 1 - z * z));
    return make_float3(r * cosf(phi), r * sinf(phi), z);
}

static void print(float3 a) { printf(" %.9g %.9g %.9g", a.x, a.y, a.z); }

int main() {
    const float ROUGHNESS[] = {0, 0.05f, 0.5f, 1}, METALLIC[] = {0, 1}, TRANSPARENCY[] = {0, 0.5f, 1};
    const float ETA[][2] = {{1, 1.5f}, {1.5f, 1}, {1, 1}};
    unsigned state = 1;
    for (float roughness : ROUGHNESS) for (float metallic : METALLIC) for (float transparency : TRANSPARENCY)
    for (const auto& eta : ETA) for (int kind = 0; kind < 4; kind++) {
        const float3 n = unit(state);
        float3 in_dir = unit(state), out_dir = unit(state), g_n = n;
        if (kind >= 2) in_dir = normalize(normalize(cross(n, in_dir)) + n * (0.001f * sign(dot(n, in_dir))));
        if (kind == 3) out_dir = normalize(normalize(cross(n, out_dir)) + n * (0.003f * sign(dot(n, out_dir))));
        if (kind % 2) g_n = normalize(n + unit(state) * 0.3f);
        Surface s{};
        s.albedo = make_float3(random(state), random(state), random(state));
        s.metallic = metallic;
        s.roughness = roughness;
        s.transparency = transparency;
        const unsigned random_state = hash(state++);
        print(in_dir); print(out_dir); print(n); print(g_n); print(s.albedo);
        printf(" %.9g %.9g %.9g %.9g %.9g %u", metallic, roughness, transparency, eta[0], eta[1], random_state);
        print(BSDF(in_dir, out_dir, n, g_n, s, eta[0], eta[1], make_float2(0, 0)));
        const SampleBSDF sample = sampleBSDF(in_dir, n, s, eta[0], eta[1], random_state);
        print(sample.unit_direction); print(sample.throughput);
        printf(" %u %d %u %.9g", sample.random_state, sample.refracted, sample.lobe, sample.pdf);
        for (unsigned lobe = 0; lobe < 3; lobe++) {
            const Lobe l = evalLobe(in_dir, out_dir, n, s, eta[0], eta[1], lobe, random_state);
            print(l.f_cos);
            printf(" %.9g", l.pdf);
        }
        printf("\n");
    }
}
