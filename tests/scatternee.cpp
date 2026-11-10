// flex-cuda-pt's light sampling at scattering vertices in the walk: from a point without a surface, all around, as
// renderer.cu's walk calls sampleLight there with no normal, no lift and both sides in the medium (66d4e7e, lines
// 1590-1593). A triangle emitting 1 toward the point is the whole scene; the samples' radiance over their density
// estimates the solid angle the triangle spans, within four standard errors, whichever way the ray reaching the point
// went, the light ahead of it or behind; and the shadow hook gets the medium the point is in. An escape after a
// scattering vertex takes the whole sky under an environment map, as no scattering vertex samples the sky. Printed:
// each reading against the closed solid angle (Van Oosterom and Strackee), and the escapes' weights
#include <stdio.h>
#include <math.h>
#include <initializer_list>
#include "pathtracer.cpp"

using V = Vector<float, 3>;
static const V A(-0.5f, -0.4f, 1), B(0.7f, -0.3f, 1), C(0.1f, 0.6f, 1), DOWN(0, 0, -1);
static uint32_t hook_filling;
Vector<uint32_t, 4> HookScene_lightNode_0(uint32_t) { return Vector<uint32_t, 4>(1, 0, 0, 0); }
uint32_t HookScene_lightSecond_0(uint32_t) { return 0; }
LightBounds HookScene_lightBounds_0(uint32_t) {
    return LightBounds{V(-0.5f, -0.4f, 1), V(0.7f, 0.6f, 1), DOWN, 1, 1};
}
uint32_t HookScene_triangleOffset_0(uint32_t) { return 0; }
Matrix<float, 3, 3> HookScene_worldTriangle_0(uint32_t, uint32_t) {
    return Matrix<float, 3, 3>(A.x, A.y, A.z, B.x, B.y, B.z, C.x, C.y, C.z);
}
Surface HookScene_surfaceAt_0(Hit, V, uint32_t state) {
    const V ONE(1, 1, 1), ZERO(0, 0, 0);
    return Surface{DOWN, DOWN, 0, {ONE, ONE, 1, 0, 0, 1, ZERO, ONE, 1}, false, state, 1, false, {ZERO, ZERO},
        0xFFFFFFFFu};
}
// A sample's emission shaded seen from the point at the origin, the light unlifted: along the point's own direction, at
// the vertex's depth (3), its distance; the samples handed otherwise counted
static int emission_misfits = 0;
Surface HookScene_lightSurfaceAt_0(Hit hit, V point, uint32_t state, V dir, uint32_t depth, float length) {
    const float distance = sqrtf(point.x * point.x + point.y * point.y + point.z * point.z);
    emission_misfits += depth != 3 || fabsf(length - distance) > 1e-6f * distance
        || (dir.x * point.x + dir.y * point.y + dir.z * point.z) < (1 - 1e-6f) * distance;
    return HookScene_surfaceAt_0(hit, point, state);
}
V HookScene_shadowTransmittanceIn_0(Ray, float, V, uint32_t filling, uint32_t, uint32_t, uint32_t, bool, float, float) {
    hook_filling = filling;
    return V(1, 1, 1);
}

// A 4 x 2 environment map, its CDF uniform over its cells, which the escape weight reads
Vector<uint32_t, 2> HookScene_environmentMapSize_0() { return Vector<uint32_t, 2>(4, 2); }
Vector<uint32_t, 2> HookScene_environmentCdfSize_0() { return Vector<uint32_t, 2>(5, 2); }
Vector<float, 4> HookScene_environmentCdf_0(Vector<uint32_t, 2> cell) {
    return Vector<float, 4>(0, cell.x == 4 ? 0.5f : 0.25f, 0, 0);
}

int main() {
    // Closed form: tan(omega / 2) = |a.(b x c)| / (|a||b||c| + (a.b)|c| + (a.c)|b| + (b.c)|a|)
    const auto len = [](V v) { return sqrt(double(v.x) * v.x + double(v.y) * v.y + double(v.z) * v.z); };
    const auto dotd = [](V a, V b) { return double(a.x) * b.x + double(a.y) * b.y + double(a.z) * b.z; };
    const double triple = A.x * (B.y * C.z - B.z * C.y) - A.y * (B.x * C.z - B.z * C.x) + A.z * (B.x * C.y - B.y * C.x);
    const double omega = 2 * atan2(fabs(triple), len(A) * len(B) * len(C) + dotd(A, B) * len(C) + dotd(A, C) * len(B)
        + dotd(B, C) * len(A));
    const int N = 1 << 20;
    int failed = 0;
    for (const V dir : {V(0, 0, 1), V(0, 0, -1), V(1, 0, 0)}) {
        double sum = 0, sum2 = 0;
        for (int i = 0; i < N; i++) {
            ShadowContext context = {V(0.1f, 0.1f, 0.1f), V(0.1f, 0.1f, 0.1f), Vector<uint32_t, 2>(9, 9), dir, 3, 0, false,
                0, 0};
            const TreeSample s = sampleLightTree_0(V(0, 0, 0), dir, dir, 0, true, hash(i), &context);
            sum += s.radiance.x, sum2 += double(s.radiance.x) * s.radiance.x;
        }
        const double mean = sum / N, se = sqrt((sum2 / N - mean * mean) / N);
        const bool ok = fabs(mean - omega) < 4 * se && hook_filling == 9 && emission_misfits == 0;
        failed += !ok;
        printf("ray along (%g, %g, %g): %.5f +- %.5f of %.5f sr%s\n", dir.x, dir.y, dir.z, mean, se, omega,
            ok ? "" : "  FAILED");
    }
    // Escapes after a scattering vertex, and after a vertex of the phase function's density, which would split them
    double least = 1, split = 1;
    for (int k = 0; k < 16; k++) {
        const V dir(cosf(0.4f * k) * 0.8f, 0.6f, sinf(0.4f * k) * 0.8f);
        least = fmin(least, escapeWeight_0(scatteredVertex_0(false).pdf, dir));
        split = fmin(split, escapeWeight_0(0.25f / 3.14159265f, dir));
    }
    const bool whole = least == 1 && split < 1;
    failed += !whole;
    printf("escape after scattering: least weight %.5f of 1 (a vertex of density 1/(4 pi) would weigh %.5f)%s\n", least,
        split, whole ? "" : "  FAILED");
    return failed;
}
