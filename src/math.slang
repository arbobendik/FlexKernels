// Constants and vector helpers as renderer.cu of flex-cuda-pt and pathtracer-compute.wgsl of FlexLight define them
module math;

public static const float PI = 3.14159265f;
public static const float BIAS = 0.0000152587890625f;
public static const float MAX_SAFE_INTEGER_FOR_F32 = 8388607.0f;
// As each consumer takes them: CUDA's rsqrtf and rnorm3df, WGSL's builtins, C++ as the host shims of the CUDA ones
public float rsqrt(float x) {
    __target_switch {
    case cuda: __intrinsic_asm "rsqrtf($0)";
    case wgsl: __intrinsic_asm "inverseSqrt($0)";
    default: return 1.0f / sqrt(x);
    }
}
public float3 normalize(float3 a) {
    __target_switch {
    case cuda: __intrinsic_asm "(($0) * make_float3(rnorm3df(($0).x, ($0).y, ($0).z)))";
    case wgsl: __intrinsic_asm "normalize($0)";
    default: return a * rsqrt(dot(a, a));
    }
}
[CudaDeviceExport] public float rgb_to_greyscale(float3 rgb) { return dot(rgb, float3(0.299f, 0.587f, 0.114f)); }
[CudaDeviceExport] public float3 safeDivide(float3 a, float3 b) {
    return float3(b.x == 0.0f ? 0.0f : a.x / b.x, b.y == 0.0f ? 0.0f : a.y / b.y, b.z == 0.0f ? 0.0f : a.z / b.z);
}
