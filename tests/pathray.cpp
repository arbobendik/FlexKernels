// Light Path depth b and lobe of the vertex before, LOBE_NONE for camera rays
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
