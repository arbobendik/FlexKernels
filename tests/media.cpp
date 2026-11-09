#include <stdio.h>
#include <initializer_list>
#include "pathtracer.cpp"

int main() {
    using V = Vector<float, 3>;
    const V up(0, 0, 1), ZERO(0, 0, 0), ONE(1, 1, 1);
    const unsigned NONE = 0xFFFFFFFFu, FILLS = 7, AIR = 3;
    const Medium carried = {V(0.1f, 0.1f, 0.1f), V(0.2f, 0.2f, 0.2f)}, volume = {V(1, 2, 3), V(4, 5, 6)};
    int cases = 0, differ = 0;
    for (const bool encloses : {false, true})
        for (const float arriving : {-1.0f, 1.0f})  // Along -f (entering a volume behind f) or along f (leaving it)
            for (const float facing : {-1.0f, 1.0f})  // The faced normal g = facing f
                for (const float tilt : {0.0f, 0.6f})
                    for (int k = 0; k < 16; k++) {
                        const float a = 0.4f * k;
                        const V f = up, g(0, 0, facing), in(0.6f, 0, 0.8f * arriving);
                        const V side(tilt * facing, 0, facing * sqrtf(1 - tilt * tilt)), dir(cosf(a), 0, sinf(a));
                        Surface surface = {up, f, 1e-4f, {ONE, ZERO, 1, 0, 0, 1, ZERO, ONE, 1}, false, 0, 1,
                            encloses, volume, FILLS};
                        Medium medium = carried;
                        const MediumSides sides = mediumSides_0(&surface, &medium, AIR, in);
                        const bool front = ((dot_0(dir, side) > 0.0f) == (dot_0(g, f) > 0.0f));
                        const Medium left = front ? sides.front : sides.behind;
                        const unsigned filling = front ? sides.fillings.y : sides.fillings.x;
                        // sides[0] behind g, sides[1] in front of it
                        Medium fcpt[2] = {carried, carried};
                        unsigned fill[2] = {AIR, AIR};
                        if (encloses) {
                            const bool back = dot_0(g, f) < 0, ahead = dot_0(g, f) > 0;
                            fcpt[back] = volume, fill[back] = FILLS;
                            if (dot_0(in, f) > 0) fcpt[ahead] = Medium{ZERO, ZERO}, fill[ahead] = NONE;
                        }
                        const unsigned i = dot_0(dir, side) > 0;
                        cases++, differ += left.scatter.x != fcpt[i].scatter.x
                            || left.extinction.z != fcpt[i].extinction.z || filling != fill[i];
                    }
    int turns = 0;
    for (const float transmission : {0.0f, 1.0f})
        for (int k = 0; k < 16; k++) {
            const float a = 0.4f * k;
            Surface s = {up, up, 1e-4f, {ONE, ZERO, 1, 0, transmission, 1.5f, ZERO, ONE, 1}, false, 0, 1, false,
                {ZERO, ZERO}, NONE};
            const V in(cosf(a), 0, sinf(a));
            const bool turned = facingSign(s.material.transmission, s.geometry_n, in) < 0;
            const V g = facingRay_0(&s, in).geometry_n, back = turned ? V(-g.x, -g.y, -g.z) : g;
            turns += back.z != up.z;
        }
    printf("media: %d of %d sides left into differ from flex-cuda-pt's, %d of 32 faces rebuilt wrong%s\n", differ,
        cases, turns, differ || turns ? "  FAILED" : "");
    return differ != 0 || turns != 0;
}
