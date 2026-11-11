// flex-cuda-pt's shadow segments in the walk: light sampling hands the shadow hook the extinction and varying medium's
// key on the side of the vertex the light is on, by side_n, as renderer.cu's sampleLight starts in sides[dot(face,
// toLight) > 0] (66d4e7e, lines 1145-1146), with the light pick's random state, the vertex's depth and arrival lobe, and
// its segment's length and width.
// Over faces bounding a volume or not, met entering or leaving it, faced either way, side_n on the faced normal or
// tilted, lights all around: the hook's medium against flex-cuda-pt's. Printed: the cases that differ
#include <stdio.h>
#include <math.h>
#include <initializer_list>
#include "pathtracer.cpp"

using V = Vector<float, 3>;
static V got_extinction(0, 0, 0);
static uint32_t got_filling, got_state, got_depth, got_lobe;
static float got_length, got_width;
static bool got_surface;
V HookScene_shadowTransmittanceIn_0(Ray, float, V extinction, uint32_t filling, uint32_t state, uint32_t depth,
    uint32_t lobe, bool surface, float length, float width, Hit) {
    got_extinction = extinction, got_filling = filling, got_state = state, got_depth = depth, got_lobe = lobe;
    got_surface = surface, got_length = length, got_width = width;
    return V(1, 1, 1);
}

int main() {
    const V up(0, 0, 1), ZERO(0, 0, 0), ONE(1, 1, 1);
    const unsigned NONE = 0xFFFFFFFFu, FILLS = 7, AIR = 3;
    const V carried(0.2f, 0.2f, 0.2f), extinct(4, 5, 6);
    int cases = 0, differ = 0;
    for (const bool encloses : {false, true})
        for (const float arriving : {-1.0f, 1.0f})
            for (const bool turned : {false, true})
                for (const float tilt : {0.0f, 0.6f})
                    for (int k = 0; k < 16; k++) {
                        const float a = 0.4f * k, facing = turned ? -1.0f : 1.0f;
                        const V f = up, g(0, 0, facing), in(0.6f, 0, 0.8f * arriving), light(cosf(a), 0, sinf(a));
                        const V side(tilt * facing, 0, facing * sqrtf(1 - tilt * tilt));
                        // The surface as the walk holds it, faced, and the face's volume as K17a carries it
                        Surface faced = {up, g, 0, {ONE, ZERO, 1, 0, 0, 1, ZERO, ONE, 1}, false, 0, 1, encloses,
                            {ONE, extinct}, FILLS};
                        Hit none = {Vector<float, 2>(0, 0), 0xFFFFFFFFu, 0, 0, 0};
                        ShadowContext context = shadowContext_0(&faced, turned, side, carried, AIR, in, 5, 2, 0.75f,
                            0.125f, false, ZERO, &none);
                        lightTransmittance_0(ZERO, light, 0, light, &context, 77);
                        // flex-cuda-pt's, indexed by the faced normal
                        V ext[2] = {carried, carried};
                        unsigned fill[2] = {AIR, AIR};
                        if (encloses) {
                            const bool back = dot_0(g, f) < 0, ahead = dot_0(g, f) > 0;
                            ext[back] = extinct, fill[back] = FILLS;
                            if (dot_0(in, f) > 0) ext[ahead] = ZERO, fill[ahead] = NONE;
                        }
                        const unsigned i = dot_0(side, light) > 0;
                        cases++, differ += got_extinction.x != ext[i].x || got_extinction.z != ext[i].z
                            || got_filling != fill[i] || got_state != 77 || got_depth != 5 || got_lobe != 2
                            || !got_surface || got_length != 0.75f || got_width != 0.125f;
                    }
    printf("shadow media: %d of %d hooks handed another medium than flex-cuda-pt's%s\n", differ, cases,
        differ ? "  FAILED" : "");
    return differ != 0;
}
