module math;

public static const float PI = 3.141592653589793;
public static const float MAX_SAFE_INTEGER_FOR_F32 = 8388607.0;
public static const uint UINT_MAX = 4294967295u;
public static const float BIAS = 0.0000152587890625;

// Target plumbing: the WGSL builtins the shared code calls, lowered to what each consumer calls in their place, CUDA's
// intrinsics in flex-cuda-pt and their host shims for C++
public float3 normalize(float3 a) {
    __target_switch {
    case cuda: __intrinsic_asm "(($0) * make_float3(rnorm3df(($0).x, ($0).y, ($0).z)))";
    case wgsl: __intrinsic_asm "normalize($0)";
    default: return a * (1.0f / sqrt(dot(a, a)));
    }
}
// Target plumbing: WGSL's inverseSqrt, as normalize
public float inverseSqrt(float x) {
    __target_switch {
    case cuda: __intrinsic_asm "rsqrtf($0)";
    case wgsl: __intrinsic_asm "inverseSqrt($0)";
    default: return 1.0f / sqrt(x);
    }
}
// Target plumbing: WGSL's select, in its argument order f, t, cond
[ForceInline] public float3 select(float3 f, float3 t, bool cond) { return select(cond, t, f); }
[ForceInline] public float3 select(float3 f, float3 t, bool3 cond) { return select(cond, t, f); }
// Target plumbing: x as is, but an expression Slang can't equate with an equal one before it, which it would reuse
// where the WGSL repeats it, and GPU drivers then fuse the multiply-adds around it otherwise
public float unshared(float x) {
    __target_switch {
    case wgsl: __intrinsic_asm "$0";
    default: return x;
    }
}
