// flex-cuda-pt's Light Path inputs at the walk's vertices: the walk hands its surface hook the bounce depth b and the
// lobe the ray left the vertex before by, none (3) for camera rays, as renderer.cu's walk shades each vertex (66d4e7e,
// line 1273: `b ? prev.lobe : LOBE_NONE`), over depths 0 to 63 and its three lobes. Printed: the cases that differ
#include <stdio.h>
#include "pathtracer.cpp"

int main() {
    const unsigned FCPT_LOBE_NONE = 3;
    int differ = 0;
    for (unsigned b = 0; b < 64; b++)
        for (unsigned lobe = 0; lobe < 3; lobe++)
            differ += arrivalLobe_0(b, lobe) != (b ? lobe : FCPT_LOBE_NONE);
    printf("path ray: %d of 192 lobes differ from flex-cuda-pt's%s\n", differ, differ ? "  FAILED" : "");
    return differ != 0;
}
