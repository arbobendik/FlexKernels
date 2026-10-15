// Constants and vector helpers as renderer.cu of flex-cuda-pt defines them
module math;

public static const float PI = 3.14159265f;
public static const float INV_PI = 0.3183098861837907f;
public static const float BIAS = 0.0000152587890625f;
// -1, 0 or 1
public float sign(float x) { return float(x > 0) - float(x < 0); }
// With the portable rsqrt for CUDA's rnorm3df, the near-delta lobes amplify the rounding of x / length(x)
public float3 normalize(float3 a) { return a * rsqrt(dot(a, a)); }
public float3 mix(float3 a, float3 b, float t) { return a * (1 - t) + b * t; }
[CudaDeviceExport] public float rgb_to_greyscale(float3 rgb) { return dot(rgb, float3(0.299f, 0.587f, 0.114f)); }
