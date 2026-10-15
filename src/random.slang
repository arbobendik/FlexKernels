module random;

[CudaDeviceExport] public uint hash(uint x) { // PCG
    x = x * 747796405u + 2891336453u;
    x = ((x >> ((x >> 28) + 4)) ^ x) * 277803737u;
    return (x >> 22) ^ x;
}
[CudaDeviceExport] public float random(inout uint state) { state = hash(state); return float(state >> 8) * 0x1p-24f; }
__extern_cpp public struct Random { __extern_cpp public uint state; __extern_cpp public float value; };
// The state advanced and the value drawn from it
[CudaDeviceExport] public Random pcg(uint state) {
    const float value = random(state);
    return { state, value };
}
