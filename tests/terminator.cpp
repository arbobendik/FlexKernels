// The walk's side at a vertex whose smooth normal tilts off the face: opaque and seen from the smooth normal's
// side light and bounces leave by the smooth normal's side, else by the face's. Then under a uniform sky of 1, which
// sky sampling draws uniformly (density 1 / 4pi): sky samples weighted by skyBSDF plus BSDF sampled escapes weighted
// against them by the balance heuristic read what escapes alone read, the walk's wrong-side rays mirrored across the
// face at no density, within four standard errors; directions between face and smooth normal (the terminator's wedge)
// count for both strategies or neither. Printed: the share of the escapes' reading that falls in the wedge
#include <stdio.h>
#include <math.h>
#include "pathtracer.cpp"

int main() {
    const auto dot = [](Vector<float, 3> a, Vector<float, 3> b) { return a.x * b.x + a.y * b.y + a.z * b.z; };
    const Vector<float, 3> ZERO(0, 0, 0), ONE(1, 1, 1), face(0, 0, 1);
    const Material WHITE = {ONE, ZERO, 1, 0, 0, 1, ZERO, ONE, 1}, GLASS = {ONE, ZERO, 1, 0, 1, 1.5f, ZERO, ONE, 1};
    const float SKY = 1 / (4 * float(M_PI)), TILTS[] = {0.5236f, acosf(0.3122499f)};  // 30 degrees, FlexLight's sheet
    int failed = 0;
    for (const float tilt : TILTS) {
        const Vector<float, 3> smooth(sinf(tilt), 0, cosf(tilt)), down(0, 0, -1), behind(-cosf(tilt), 0, sinf(tilt));
        const Surface surface = {smooth, face, 1e-4f, WHITE, false, 0};
        // Which normal decides the side: the smooth one from its side when opaque, the face's otherwise
        const bool sides = dot(sideNormal(surface, down), smooth) > 0.9999f
            && dot(sideNormal({smooth, face, 1e-4f, GLASS, false, 0}, down), face) > 0.9999f
            && dot(sideNormal(surface, Vector<float, 3>(-behind.x, 0, -behind.z)), face) > 0.9999f;
        const Vector<float, 3> side = sideNormal(surface, down);
        // Sky samples, then BSDF samples as the walk takes them: wrong side by side, mirrored across the face
        const int N = 1 << 21;
        double nee = 0, nee2 = 0, gap = 0, gap2 = 0, alone = 0, wedge = 0;
        for (int i = 0; i < N; i++) {
            const Random u = pcg(hash(2 * i + 1)), v = pcg(u.state);
            const float z = 1 - 2 * u.value, r = sqrtf(fmaxf(0, 1 - z * z)), phi = 2 * float(M_PI) * v.value;
            const Vector<float, 3> d(r * cosf(phi), r * sinf(phi), z);
            const double s = skyBSDF(down, d, surface, side, Vector<float, 2>(1, 1), false, SKY, v.state).x;
            nee += s, nee2 += s * s;
            SampleBSDF b = sampleBSDF(down, smooth, WHITE, 1, 1, hash(2 * i + 2), Vector<float, 2>(0, 0));
            const bool wrong = (b.refracted == false) != (dot(b.unit_direction, side) > 0);
            const float pdf = wrong ? 0 : b.pdf;
            if (wrong) b.unit_direction.z = -b.unit_direction.z;  // Mirrored across the face, +z
            const double t = b.throughput.x, w = pdf > 0 ? pdf / (pdf + SKY) : 1;
            alone += t, gap += t * (w - 1), gap2 += t * (w - 1) * t * (w - 1);
            if (dot(b.unit_direction, smooth) * dot(b.unit_direction, face) < 0) wedge += t;
        }
        // Sum of both strategies minus escapes alone: sky mean minus the escapes' unweighted share
        const double difference = (nee + gap) / N;
        const double se = sqrt((nee2 / N - nee * nee / N / N) / N + (gap2 / N - gap * gap / N / N) / N);
        const bool ok = sides && fabs(difference) < 4 * se;
        failed += !ok;
        printf("tilt %.4f: sides %s, sky + weighted escapes - escapes %.5f +- %.5f of %.4f, wedge share %.4f%s\n", tilt,
            sides ? "ok" : "WRONG", difference, se, alone / N, wedge / alone, ok ? "" : "  FAILED");
    }
    return failed;
}
