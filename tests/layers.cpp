#include <stdio.h>
#include <initializer_list>
#include "pathtracer.cpp"

int main() {
    const Vector<float, 3> ONE(1, 1, 1), ZERO(0, 0, 0), up(0, 0, 1), in(0.6f, 0, -0.8f), out(0.6f, 0, 0.8f);
    Surface top = {up, up, 1e-4f, {ONE, ONE, 1, 0, 0, 1, ZERO, ONE, 1}, false, 0, 1};
    const Surface lower = emitting_0(&top, false), upper = emitting_0(&top, true);
    const bool emits = upper.material.emissive.x == 1 && lower.material.emissive.x == 0 && lower.material.albedo.x == 1;
    const Vector<float, 2> NO_SCREEN(0, 0);
    int met = 0, wrong = 0, alone = 0, smooth = 0;
    for (const float roughness : {0.0f, 0.5f})
        for (const float transmission : {0.0f, 1.0f}) {
            Surface coat = {up, up, 1e-4f, {ONE, ZERO, 0, 0, 1, 1.5f, ZERO, ONE, 1}, false, 0, 1};
            Surface base = {up, up, 1e-4f, {ONE, ZERO, roughness, 0, transmission, 1.5f, ZERO, ONE, 1}, false, 0, 1};
            for (int i = 0; i < 4096; i++) {
                Vector<float, 2> eta = vertexEta(coat.material, -in.z);
                const SampleBSDF c = sampleBSDF(in, up, coat.material, eta.x, eta.y, hash(3 * i + 1), NO_SCREEN);
                if (!c.refracted) continue;
                Surface b = facingRay_0(&base, c.unit_direction);
                bool inside = arrivesBehind_0(c.unit_direction, b.geometry_n);
                eta = vertexEta(b.material, dot_0(b.smooth_n, -c.unit_direction));
                const SampleBSDF d = sampleBSDF(c.unit_direction, b.smooth_n, b.material, eta.x, eta.y, hash(3 * i + 2),
                    NO_SCREEN);
                met++, wrong += wrongSide_0(inside, d.refracted, d.unit_direction, b.geometry_n);
                alone += wrongSide_0(false, d.refracted, d.unit_direction, b.geometry_n);
                smooth += roughness == 0 && wrongSide_0(inside, d.refracted, d.unit_direction, b.geometry_n);
                if (d.refracted || !(d.unit_direction.z > 0)) continue;
                Surface a = facingRay_0(&coat, d.unit_direction);
                inside = arrivesBehind_0(d.unit_direction, a.geometry_n);
                eta = vertexEta(a.material, dot_0(a.smooth_n, -d.unit_direction));
                const SampleBSDF e = sampleBSDF(d.unit_direction, a.smooth_n, a.material, eta.x, eta.y,
                    hash(3 * i + 3), NO_SCREEN);
                met++, wrong += wrongSide_0(inside, e.refracted, e.unit_direction, a.geometry_n);
                alone += wrongSide_0(true, e.refracted, e.unit_direction, a.geometry_n);
                smooth += roughness == 0 && wrongSide_0(inside, e.refracted, e.unit_direction, a.geometry_n);
            }
        }
    const bool ok = emits && met > 0 && wrong == alone && !smooth;
    printf("layers: lower layers %s, at layers passed on to %d of %d samples on the wrong side (without layers %d, "
        "at roughness 0 %d)%s\n", emits ? "dark" : "EMIT", wrong, met, alone, smooth, ok ? "" : "  FAILED");
    return !ok;
}
