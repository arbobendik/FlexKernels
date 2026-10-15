# Unifying the FlexCudaPT and FlexLight kernels

Line numbers refer to flex-cuda-pt `e5783f8` (`cu` = `src/shaders/renderer.cu`, `h` = `src/shaders/renderer.h`) and
FlexLight `828c482` (`wgsl` = `src/flexlight/webgpu/shaders/pathtracer-compute.wgsl`, `shift` =
`.../pathtracer-shift.wgsl`, `ts` = `src/flexlight/webgpu/restir.ts`), before either consumed FlexKernels.

Categories: **1** identical or trivially unifiable, **2** diverged but unifiable (reference side named), **3**
backend-specific. **Ported** marks what `src/*.slang` now holds for both.

## Classification

### Vector, random and BSDF helpers

| Name | CUDA | WGSL | Cat | Reference | Notes |
|---|---|---|---|---|---|
| `Matrix` | cu:11 | – (`mat3x3<f32>`) | 1 | CUDA | **Ported** as `Frame`: the Slang CUDA prelude defines a `Matrix` template |
| float3/float2 operators | cu:12-19, 40 | builtin | 1 | – | WGSL and Slang have them built in; `operator-(float2)` only served `normalMapTBN` |
| `xzy` | cu:20 | swizzle | 1 | – | **Ported** as the `.xzy` swizzle |
| `mix` (float3) | cu:21 | builtin `mix` | 1 | CUDA | **Ported** as written (`a * (1 - t) + b * t`); the float4 one stays for `shade` |
| `sign` | cu:27 | builtin | 1 | CUDA | **Ported**: CUDA's is 0 for NaN, which `refract_component` relies on under total internal reflection |
| `dot`, `cross`, `length` | cu:28, 35, 39 | builtin | 1 | – | Slang builtins in the shared code, CUDA keeps its own for the rest |
| `reflect`, `refract` | cu:29, 31 | builtin | 1 | – | Same formulas (refract is zero under TIR), Slang builtins |
| `normalize` | cu:38 | builtin | 1 | CUDA | **Ported** as `a * rsqrt(dot(a, a))`, the portable form of `rnorm3df`; `x / length(x)` drifts by 2-4 % in the near-delta densities |
| `wrap` | cu:42 | `fract` in `surfaceAt` | 3 | – | Texture addressing |
| `hash` | cu:43 | wgsl:1889 | 1 | – | **Ported**, identical |
| `random` | cu:48 | – | 2 | CUDA | **Ported**, `inout` lowers to a pointer: CUDA call sites pass `&state` |
| `Random` | cu:49 | wgsl:227 | 1 | – | **Ported** |
| `RandomSphere`, `RandomHemisphere` | cu:50, 51 | wgsl:232, 237 | 1 | – | Unused by the BSDF; CUDA has no caller. Left in place |
| `pcg` | cu:53 | wgsl:246 | 2 | CUDA | **Ported**. WGSL returned the LCG state instead of the hash and `value / UINT_MAX`, which reaches 1. FlexLight's random streams change |
| `rgb_to_greyscale` | cu:57 | wgsl:242 | 1 | – | **Ported** |
| `normal_distribution`, `random_sphere`, `random_hemisphere` | cu:65, 74, 81 | wgsl:257, 266, 273 | 1 | – | Not BSDF dependencies: left, now on the shared `pcg` |
| `smithG1` | cu:59 | wgsl:1984 | 1 | – | **Ported** |
| `trowbridgeReitz`, `G1`, `schlickBeckmann`, `smith` | cu:92, 98, 111, 115 | wgsl:691, 697, 710, 714 | 1 | – | **Ported** |
| `delta`, `smithAlt`, `fresnel_schlick`, `sampleTrowbridgeReitz` | cu:103, 121, 127, 153 (comments) | wgsl:702 (comment), 720, 726, 752 (comments) | – | – | Dead in both, not ported |
| `fresnel` | cu:133 | wgsl:732 | 1 | – | **Ported** |
| `sampleGGXVNDF`, `sampleCosWeightedHemisphere` | cu:162, 184 | wgsl:761, 783 | 1 | – | **Ported** |
| `tangentToWorld`, `worldToTangent` | cu:193, 203 | wgsl:792, 802 | 1 | – | **Ported** |
| `normalMapTBN` | cu:215 | wgsl:814 | 2 | CUDA | **Ported**. WGSL flipped the tangent when `cross(n, t)` agreed with the UV bitangent, which mirrored X in right-handed UVs; CUDA keeps T and turns B along the UV bitangent as Blender. FlexLight keeps its green flip at the call site, its textures start at the top row |
| `tangentToWorldNormalMap` | cu:234 | wgsl:836 | 1 | – | **Ported**, takes `Frame` |
| `BSDF` | cu:240 | wgsl:842 | 2 | CUDA | **Ported**. WGSL's BTDF was not tinted by albedo. `screen_space` was unused in both and is dropped |
| `SampleBSDF` | cu:307 | wgsl:905 | 1 | – | **Ported** |
| `sampleBSDF` | cu:318 | wgsl:916 | 2 | CUDA | **Ported**. WGSL desaturated the reflection by `transmission` (`colorless_reflection`) and left the BTDF uncolored |
| `Lobe` | cu:603 | wgsl:1872 | 1 | – | **Ported** |
| `evalLobe` | cu:733 | wgsl:1991 | 2 | CUDA | **Ported**, same two WGSL differences as `sampleBSDF` |
| `neeDecision` | cu:537 | wgsl:1386 | 1 | – | **Ported**: same math, and moving it spared adapting its WGSL copy to `Surface` |

### Surfaces, lights and media

| Name | CUDA | WGSL | Cat | Reference | Notes |
|---|---|---|---|---|---|
| `Surface` (shared) | h:13 | – | 1 | CUDA | **Ported**, layout kept: `shade` brace-initializes it from its stack |
| `Material` | h:18 | wgsl:104 | 3 | – | CUDA: light power, program, hidden. WGSL: PBR constants laid out by the TypeScript upload |
| `Surface` (FlexLight) | – | wgsl:1273 | 3 | – | Hit record (normals, offset, material, skip), renamed `HitSurface`; its `material` is a shared `Surface` |
| `Op`, op enum | h:9, 11 | – | 3 | – | Node program, a union |
| `logarithm`, `divide` | cu:473, 474 | – | 1 | – | Program math, CUDA only so far |
| `texel` | cu:477 | `access_*` wgsl:135-169 | 3 | – | Data access |
| `shade` (program) | cu:481 | `surfaceAt` wgsl:1283 | 3 | CUDA | Blender node interpreter vs fixed texture slots. Unifying needs a texture interface and the program in a buffer |
| `shade` (triangle) | cu:522 | `surfaceAt` wgsl:1283 | 3 | – | Vertex fetch differs (flat pointers vs instanced textures) |
| `textureSample` | – | wgsl:181 | 3 | – | |
| `beerLambert` | cu:532 | wgsl:1378 | 2 | CUDA | CUDA is Cycles' volume absorption (`absorption`, `density`), WGSL absorbs by albedo per instance. Needs both fields in FlexLight's `Material` |
| `faceNormal`, `smoothNormal`, `geometryOffset` | cu:639, 644, 652 | inline in `surfaceAt` | 2 | CUDA | Same math (WGSL via `tan(acos)`), data access differs; CUDA isolates it |
| `hitPosition` | cu:634 | wgsl:1916 | 3 | – | Instance transforms in WGSL |
| `sampleLight` | cu:699 | wgsl:1088 | 2 | CUDA | CUDA picks triangles by emitted power (binary search), WGSL lights uniformly and has point lights; `occluded` (wgsl:1188) is its shadow ray |
| `LightSample`, `NEESample`, `reservoirSample`, `calculatePointLightContrib` | – | wgsl:1079, 1200, 1212, 1268 | 3 | – | FlexLight's light list and point lights |
| `environment` | cu:690 | wgsl:1966, `env_map_sample` 1559 | 3 | – | World shader program vs equirectangular map or ambient |
| `environmentMapped`, `environmentPdf`, `searchCDF`, `skyRadiance`, `SkySample`, `sampleSky`, `skyBSDF`, `escapeWeight` | – | wgsl:1572-1656 | 3 | – | FlexLight's environment NEE, built on `evalLobe` |
| `Light`, `SamplePreCalc`, `SampledColor` | – | wgsl:113, 1067, 1074 | 3 | – | `SamplePreCalc` is unused |
| `lightTrace` | – | wgsl:1394 | 2 | CUDA | FlexLight's non-ReSTIR path tracer; CUDA traces both through `walk` |

### Traversal, ReSTIR and entry points

| Name | CUDA | WGSL | Cat | Reference | Notes |
|---|---|---|---|---|---|
| `Hit` | h:21 | wgsl:126 | 3 | – | CUDA: triangle and barycentrics. WGSL adds instance, point light flag and distance |
| `Ray`, `Intersect` | – | wgsl:99, 121 | 3 | – | |
| `traverse` | cu:624 | `traverseInstanceBVH` wgsl:469 | 3 | – | `optixTraverse` and hit objects vs software BVH: the `ITracer` below |
| `moellerTrumbore`, `moellerTrumboreCull`, `rayBoundingVolume`, `raySphere`, `traverseTriangleBVH`, `shadowTraverseTriangleBVH`, `shadowTraverseInstanceBVH` | – | wgsl:284-628 | 3 | – | The software BVH tracer |
| `Camera`, `Settings`, `Scene` | h:5, 40, 47 | `UniformFloat`, `UniformUint` wgsl:39, 52; shift:12, 22 | 3 | – | Bindings |
| `Transform` | – | wgsl:34, shift:7 | 3 | – | Instances |
| `Reservoir` | h:23 | wgsl:1840 | 2 | CUDA | `rc` is a `Hit` vs `vec4<u32>` (instance, triangle, uv or light, state) |
| `Shift` | h:37 | wgsl:1877 | 1 | – | Identical |
| `Selection` | cu:608 | wgsl:1882 | 1 | – | Identical |
| `Domain` | cu:589 | wgsl:1857 | 2 | CUDA | Holds the backend's `Hit` |
| `Vertex` | cu:596 | wgsl:1864 | 2 | CUDA | WGSL tracks `inside`, CUDA derives it from the face |
| `stream` | cu:615 | wgsl:1895 | 1 | – | Identical |
| `extractBits` | cu:619 | builtin | 1 | – | WGSL builtin; `withEnd` uses `insertBits` there |
| `wrongSide` | cu:668 | wgsl:2090 | 2 | CUDA | WGSL passes an `is_inside` flag, CUDA the incoming direction |
| `pixelDomain` | cu:674 | `currentDomain`, `storedDomain`, `hitDomain`, `previousDomain` wgsl:1927-1958 | 3 | – | Jittered camera rays vs the raster G-buffer |
| `vertexEta` | inline in `walk` | wgsl:1974 | 1 | – | |
| `safeDivide` | cu:727 | wgsl:1979 | 1 | – | |
| `offer`, `offerShifted`, `finalize` | cu:799, 813, 820 | wgsl:2051, 2067, 2074 | 1 | – | Identical now that `random(state)` and `pcg(state)` draw the same numbers |
| `withEnd` | cu:828 | wgsl:2082 | 1 | – | Bit-or vs `insertBits`, the same for empty fields. WGSL has `END_POINT`, `END_SKY` and `PATH_INSIDE` on top |
| `walk` | cu:839 | wgsl:2098 | 2 | CUDA | Shared once behind `ITracer` and a scene interface, see below |
| `shift` | cu:1084 | wgsl:2438 | 2 | CUDA | Domain construction differs |
| `project`, `previousValid`, `temporalNeighbor` | cu:1097, 1106, 1115 | wgsl:2400, 2406, 2411 | 2 | CUDA | Camera basis vs view matrix |
| `partner` | cu:1132 | wgsl:2426 | 1 | – | Same math, the pairing texture is `char2*` vs `texture_2d_array<i32>` |
| `loadReservoir`, `storeReservoir` | – | wgsl:1899, 1908 | 3 | – | Reservoirs packed into textures |
| `ShiftQueue`, `sameDomain`, `ShiftJob`, `temporalJob`, `spatialJob`, `shiftBin`, `temporalBins`, `spatialBins`, `countShifts`, `queueShifts`, `queuedShift` | – | wgsl:1832, 2502-2624 | 3 | – | Binning of shifts by depth for WebGPU occupancy |
| `__raygen__initial`, `temporal`, `shift`, `spatial`, `duplicates` | cu:1151-1268 | `restir_*` wgsl:2449-2775, `compute` wgsl:1665 | 3 | – | Entry points; the duplicate count is the same math |
| `compute` (shift pass) | – | shift:49 | 3 | – | Accumulation reprojection |
| `pairingTexture`, `ReSTIR`, `ReSTIRResources` | – | ts:34, 64, 27 | 3 | – | Host side: WGSL has no includes, `pathtracer.ts` prepends the shared code once |

## Data model mismatches

- `Scene` is pointer-heavy (`float3*`, `Op*`, `Reservoir*`, ...). WGSL structs hold no pointers or runtime arrays, so
  shared code can't take a scene. It takes values, and data access goes behind interfaces implemented per backend.
- `Op` has a union of `float3` and three `unsigned`. Slang has no unions; the program needs a tagged layout or a
  reinterpreting `uint4` encoding before `shade` can be shared.
- `char2` in `pairing` (WGSL reads `rg8sint` as `i32`) and `unsigned long long` for the traversable handle (WGSL has
  no 64-bit integers) stay on the CUDA side of the interface.
- FlexLight is at `maxStorageBuffersPerShaderStage` = 8 already, which is why triangles, BVH, textures and reservoirs
  live in textures. Shared code adds no bindings and should never declare any: every buffer goes through a
  backend-implemented interface.
- `bool` fields (`SampleBSDF.refracted`, `Vertex.rough`) are not host-shareable in WGSL; fine for function-local
  structs only. `Hit`, `Reservoir.rc` and `Material` have different layouts per backend (instances, point lights).
- WGSL has no references: Slang `inout` lowers to `ptr<function, T>` there and to `T*` in CUDA.

## Toolchain decisions

- Slang 2026.19, the latest stable release, is fetched into `.deps/slang` by the `Makefile`. `src/bsdf.slang` imports
  `math.slang` and `random.slang` and is compiled once per target, so dependencies are never duplicated across files.
- Stable names: exported functions carry `[CudaDeviceExport]`, which keeps them alive and unmangled for CUDA, WGSL
  and C++ alike; structs and their fields carry `__extern_cpp`. Everything else gets Slang's `_0` suffix (CUDA
  `static`), which no consumer uses. Consumers lost the definitions the shared header now provides: CUDA `Random`,
  `Matrix`, `Lobe`, `hash`, `random`, `pcg`, ...; WGSL `Random`, `Lobe`, `hash`, `pcg`, ..., and FlexLight's own
  `Surface` became `HitSurface`.
- slangc writes the prelude include as an absolute path into the installation; the `Makefile` rewrites that one
  `#include` line to the copy next to the header. No identifiers are rewritten.
- The CUDA prelude raises warning #1444 (deprecated `ulonglong4`) under CUDA 13; harmless.
- `Material` → `Surface` in FlexLight, built once in `surfaceAt`: `normal` = smooth normal, `albedo`, `metallic`,
  `roughness`, `emissive`, `ior` as is, `transparency` = `transmission`, `absorption` = 1 and `density` = 0, as its
  `beerLambert` absorbs by the albedo instead.

## Parity

Goldens: `tests/golden.txt`, 288 cases (roughness 0, 0.05, 0.5, 1 × metallic 0, 1 × transparency 0, 0.5, 1 ×
entering, leaving with total internal reflection and no index change × random, offset geometry normal, grazing
incidence, grazing incidence and exitance) of `BSDF`, `sampleBSDF` and `evalLobe` for each lobe. `make golden`
host-compiles the unmodified `renderer.cu` of flex-cuda-pt `e5783f8` against `tests/shim` and reproduces them
byte for byte.

Tolerance: integers (random state, lobe, refraction) exactly; floats within
`1e-5 + (1e-3 + 8 * 2^-23 / alpha^2) * |golden|`, as the GGX denominator `n_dot_h^2 (alpha^2 - 1) + 1` cancels down
to `alpha^2` at a lobe's peak: at roughness 0.05 one ulp moves a density by about 2 %.

| Run | Where | Result |
|---|---|---|
| `make test-cpu` | Slang C++ target, CI | 288 / 288, worst 0.000 of the tolerance |
| `make test-wgsl` | Generated WGSL through Dawn on lavapipe, CI | 288 / 288, worst 0.044 of the tolerance |
| `make test-cuda` | Generated CUDA on the local GPU | 288 / 288, worst 0.453 of the tolerance |
| `make test-hip` | hipcc 7.2.4 compile only, CI | compiles |

Worst relative error by roughness: 0, 0.5 and 1 stay within 3.1e-5 everywhere; 0.05 reaches 0.68 % in WGSL and
7.0 % in CUDA on the GPU (fused multiply-adds), the C++ target matches bit for bit.

## HIP

Slang 2026.19 has no HIP target, and its CUDA prelude does not build under hipcc (170 errors: PTX asm for surface
objects, `cudaSurfaceObject_t`, 32-bit warp masks where HIP wants 64, `bool2`/`bool4`, `__ldg` overloads). The
generated code itself does: `src/hip-prelude.h` provides the few wrappers it uses (`F32_*`, `FixedArray`, scalar
`make_float3`, `uint`), and `build/hip` pairs it with the same header. CI compiles that in `rocm/dev-ubuntu-24.04:7.2.4`.
A HIP backend still needs HIPRT traversal and a HIP build of the renderer.

## WebGL2

`src/flexlight/webgl2/shaders/*.glsl` stays as it is. The BSDF could reach it through Slang → SPIR-V → SPIRV-Cross
(`--es --version 300`): it is pure float and `uint` math with `inout` parameters, all available in GLSL ES 3.00.
SPIRV-Cross only emits what an entry point reaches, so it needs a dummy fragment entry point whose `main` and outputs
are dropped, and names survive through `OpName`. Slang's own GLSL target emits desktop GLSL 450, not ES.

## `walk` behind `ITracer` (sketch, not implemented)

```slang
interface ITracer {
    // Nearest hit within far and its distance, NONE on a miss
    Hit traverse(float3 origin, float3 direction, float far, out float distance);
}
interface IScene {
    Surface shade(Hit hit);
    float3 faceNormal(Hit hit);
    float geometryOffset(Hit hit, float3 face, float3 position);
    float3 hitPosition(Hit hit);
    float3 environment(float3 direction);
    float3 sampleLight(float3 origin, float3 normal, float offset, uint state, out float3 direction);
}
// Generic, so every backend gets a statically specialized copy without dynamic dispatch, also in WGSL
Shift walk<T : ITracer, S : IScene>(T tracer, S scene, Domain dom, Reservoir r, bool replay, float scale,
    inout Selection sel);
```

- `OptixTracer`: Slang's `HitObject` (shader execution reordering) maps onto `optixTraverse` and
  `optixHitObject*`, as `traverse` uses them now; the handle stays in the CUDA-side scene.
- `HiprtTracer`: `hiprtGeomTraversalClosest` over the same `Hit`.
- `BvhTracer`: FlexLight's `traverseInstanceBVH` and `moellerTrumbore`, reading its textures; `Hit` would carry the
  instance as FlexLight's does.

## Porting order

1. `Selection`, `Shift`, `stream`, `offer`, `offerShifted`, `finalize`, `safeDivide`: category 1, pure math. Needs a
   shared `Reservoir`, which needs a backend-neutral reconnection record (`uint4`, as WGSL has it).
2. `partner` and `withEnd`: category 1 once the pairing texture is read through the scene interface.
3. `faceNormal`, `smoothNormal`, `geometryOffset`: same math, CUDA's factoring; data access via `IScene`.
4. `beerLambert`: CUDA's Cycles absorption, once FlexLight's `Material` carries `absorption` and `density`.
5. `sampleLight` by emitted power, keeping FlexLight's point lights as a backend extra.
6. `walk` and `shift` behind `ITracer` and `IScene`; FlexLight's `lightTrace` then becomes `walk` without ReSTIR.
7. `shade`: the node program interpreter, after a union-free `Op` and a texture interface.
