# Unifying the FlexCudaPT and FlexLight kernels

Line numbers refer to the current mains, the identity baseline: flex-cuda-pt `02d0bf1` (`cu` =
`src/shaders/renderer.cu`, `h` = `src/shaders/renderer.h`) and FlexLight `5a313db` (`wgsl` =
`src/flexlight/webgpu/shaders/pathtracer-compute.wgsl`, `shift` = `.../pathtracer-shift.wgsl`, `ts` =
`src/flexlight/webgpu/restir.ts`), before either consumed FlexKernels.

A function, struct or constant in both mains is **shared** when (a) both produce the same outputs for the same inputs,
random states included, proven by goldens of both, (b) sharing it changes neither consumer's data layout, bindings,
random streams nor behavior and (c) each consumer's diff is a deletion, the include or prepend and trivial call-site
adaptation. Everything else stays local, with the reason; **Shared** marks what `src/*.slang` now holds.

## Classification

### Random numbers and helpers

| Name | CUDA | WGSL | Status | Reason |
|---|---|---|---|---|
| `hash`, `stream` | cu:43, 586 | wgsl:1854, 1860 | **Shared** | Identical |
| `Random`, `RandomSphere`, `RandomHemisphere` | cu:49-51 | wgsl:227-237 | **Shared** | Identical layouts |
| `pcg` | cu:53 | wgsl:246 | **Shared**, per target | The generators differ: CUDA advances to the hash and draws its 24 high bits, FlexLight advances the LCG state and draws the hash over `UINT_MAX`, which reaches 1. Each target keeps its consumer's exactly (`__target_switch`), never unified |
| `normal_distribution`, `random_sphere`, `random_hemisphere` | cu:67, 76, 83 | wgsl:257, 266, 273 | **Shared** | Same math on each target's `pcg`; CUDA has no caller |
| `random` | cu:48 | – | Local | CUDA only, its draw is the CUDA branch of `pcg` |
| `rgb_to_greyscale`, `safeDivide` | cu:57, 748 | wgsl:242, 1944 | **Shared** | Identical outputs (`select` vs ternaries) |
| `brightest`, `tinted` | cu:59, 123 | – | Local | CUDA only: Principled specular tint and level |
| `PI`, `BIAS`, `INV_PI`, `MAX_SAFE_INTEGER_FOR_F32` | cu:6-9 | wgsl:20-30 | Local, inlined | Equal as `f32`, but Slang inlines constants and can't export a named one (`[CudaDeviceExport]` is not valid on variables). `MAX_SAFE_INTEGER_FOR_F32` lost its only use to `normal_distribution` and is deleted in both |
| float3 operators, `xzy`, `mix`, `sign`, `dot`, `cross`, `reflect`, `refract`, `normalize`, `length`, `wrap` | cu:12-42 | builtins | Local | WGSL and Slang builtins. `xzy` lost its last use to `sampleHalfVector` and stays to keep the diff minimal |

### BSDF

| Name | CUDA | WGSL | Status | Reason |
|---|---|---|---|---|
| `smithG1`, `trowbridgeReitz`, `fresnel` | cu:61, 94, 104 | wgsl:703, 691, 708 | **Shared** | Identical; `trowbridgeReitz` is dead in CUDA |
| `sampleGGXVNDF`, `sampleCosWeightedHemisphere`, `tangentToWorld`, `worldToTangent` | cu:131, 153, 162, 172 | wgsl:726, 748, 757, 767 | **Shared** | Identical |
| `sampleHalfVector` | cu:235 | wgsl:844 | **Shared** | Identical; CUDA call sites pass `&random_state`, as Slang lowers `inout` to a pointer |
| `G1` | cu:100 | wgsl:697 | Local | CUDA is the exact Smith masking (`smithG1`), FlexLight Schlick's `k = alpha / 2` |
| `SampleBSDF` | cu:210 | wgsl:818 | Local | Identical, but Slang only emits types an exported function reaches; it comes with `sampleBSDF` |
| `BSDFLobes`, `bsdfLobes` | cu:221, 246 | wgsl:829, 855 | Local | CUDA's Fresnel is `tinted` (specular tint and level), FlexLight's plain; FlexLight adds `colorless_reflection` |
| `lobeThroughput` | cu:278 | wgsl:885 | Local | CUDA dims the diffuse lobe by the brightest tinted Fresnel channel and colors the BTDF by the albedo; FlexLight desaturates the reflection by `transmission`; the `G1` above; CUDA takes `v` |
| `lobeDensity` | cu:325 | wgsl:930 | Local | FlexLight's visible normal density takes the clamped `trowbridgeReitz`, CUDA's the unclamped GGX: they part at roughness below about 0.2 |
| `sampleBSDF`, `connectBSDF`, `BSDF` | cu:360, 411, 438 | wgsl:961, 1011, 807 | Local | Same structure on the local lobes above; `Surface` vs `Material`, unused `screen_space` |
| `neeDecision` | cu:515 | wgsl:1356 | Local | `tinted` vs plain Fresnel, and CUDA's surface has the tint and level FlexLight lacks |
| `normalMapTBN` | cu:184 | wgsl:779 | Local | WGSL flips the tangent where CUDA turns the bitangent, as Blender's tangent space |
| `tangentToWorldNormalMap` | cu:203 | wgsl:801 | Local | Same math on `Matrix` (columns) vs `mat3x3<f32>` |
| `LOBE_DIFFUSE`, `LOBE_REFRACT` | cu:207 | wgsl:1746 | Local, inlined | Equal, constants (see `PI`) |

### Surfaces, lights and media

| Name | CUDA | WGSL | Status | Reason |
|---|---|---|---|---|
| `Surface` (CUDA) | h:13 | – | Local | Program output, with tint, level and coverage |
| `Material` | h:18 | wgsl:104 | Local | Light power and program vs PBR constants laid out by the TypeScript upload |
| `Surface` (FlexLight) | – | wgsl:1243 | Local | Hit record (normals, offset, material, skip) |
| `Op`, op enum, `logarithm`, `divide`, `texel`, `shade` | h:9-11, cu:451-500 | `textureSample`, `surfaceAt` wgsl:181, 1253 | Local | Blender node interpreter vs fixed texture slots |
| `beerLambert` | cu:510 | wgsl:1348 | Local | Cycles' volume absorption vs absorption by the albedo per instance |
| `faceNormal`, `smoothNormal`, `geometryOffset`, `hitPosition` | cu:605-623 | inline in `surfaceAt`, wgsl:1881 | Local | Data access: flat pointers vs instanced textures |
| `LightNode`, `importance`, `cosSubClamped`, `sinSubClamped`, `sine`, `sampleLight` | h:22, cu:668-699 | `Light`, `sampleLight`, `occluded` wgsl:113, 1054, 1154 | Local | Light BVH by importance vs uniform lights with point lights |
| `LightSample`, `NEESample`, `reservoirSample`, `calculatePointLightContrib`, `SamplePreCalc`, `SampledColor`, `lightTrace` | – | wgsl:1033-1364 | Local | FlexLight only |
| `environment` | cu:661 | wgsl:1931 | Local | World shader program vs equirectangular map or ambient |
| `env_map_sample`, `environmentMapped`, `environmentPdf`, `searchCDF`, `skyRadiance`, `SkySample`, `sampleSky`, `skyBSDF`, `escapeWeight` | – | wgsl:1529-1626 | Local | FlexLight's environment NEE |

### Traversal, ReSTIR and entry points

| Name | CUDA | WGSL | Status | Reason |
|---|---|---|---|---|
| `Hit`, `Ray`, `Intersect`, `traverse` | h:25, cu:595 | wgsl:99-126, `traverseInstanceBVH` 469 | Local | `optixTraverse` vs the software BVH (wgsl:284-628) |
| `Camera`, `Settings`, `Scene`, `Transform`, uniforms | h:5, 44, 51 | wgsl:34-52, shift:7-22 | Local | Bindings |
| `Reservoir` | h:27 | wgsl:1810 | Local | `rc` is a `Hit` vs `vec4<u32>` |
| `Shift` | h:41 | wgsl:1842 | Local | Identical, but CUDA's is in `renderer.h`, which the host `main.cpp` sizes `Scene::shifts` with |
| `Selection`, `Domain`, `Vertex` | cu:565-579 | wgsl:1827-1847 | Local | Hold `Reservoir` or `Hit`; WGSL's `Vertex` adds `inside` |
| `offer`, `offerShifted`, `finalize` | cu:753-774 | wgsl:1949-1972 | Local | `Selection` differs; `offer` draws by `random` vs `pcg` |
| `withEnd` | cu:782 | wgsl:1980 | Local | `Reservoir` differs; bit-or vs `insertBits` |
| `extractBits` | cu:590 | builtin | Local | WGSL builtin |
| `wrongSide` | cu:639 | wgsl:1988 | Local | Incoming direction vs an `is_inside` flag |
| `vertexEta` | inline in `walk` | wgsl:1939 | Local | Not a CUDA function |
| `RESTIR_*`, `END_NEE`, `END_EMIT`, `RC_*`, `PATH_*` (but `PATH_INSIDE`), `STREAM_NEE`, `STREAM_RR`, `STREAM_SELECT` | cu:529-562 | wgsl:1738-1777 | Local, inlined | Equal, constants (see `PI`). `END_ENV` is 2 vs 3, `STREAM_JITTER`/`STREAM_COVERAGE` vs `STREAM_SPHERE`/`STREAM_SKY` |
| `walk`, `shift`, `pixelDomain` | cu:793, 1046, 645 | wgsl:1996, 2335, `currentDomain`... 1892-1923 | Local | Behind `ITracer` and a scene interface, see below |
| `project`, `previousValid`, `temporalNeighbor`, `partner` | cu:1059-1094 | wgsl:2297-2323 | Local | Camera basis vs view matrix; pairing `char2*` vs `texture_2d_array<i32>` |
| `loadReservoir`, `storeReservoir`, `ShiftQueue`, `sameDomain`, `ShiftJob`, ... `queuedShift` | – | wgsl:1802, 1864-1873, 2399-2521 | Local | Reservoir textures and shift binning of FlexLight |
| `__raygen__initial`, `temporal`, `shift`, `spatial`, `duplicates` | cu:1113-1230 | `compute`, `restir_*` wgsl:1635, 2346-2672 | Local | Entry points |
| `compute` (shift pass), `pairingTexture`, `ReSTIR` | – | shift:49, ts:34, 64 | Local | Accumulation reprojection, host side |

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

- Slang 2026.19, fetched into `.deps/slang` by the `Makefile`. `src/bsdf.slang` imports `math.slang` and
  `random.slang` and is compiled once per target, so dependencies are never duplicated across files.
- Stable names: exported functions carry `[CudaDeviceExport]`, which keeps them alive and unmangled for CUDA, WGSL
  and C++ alike; structs and their fields carry `__extern_cpp`. Everything else gets Slang's `_0` suffix (CUDA
  `static`). None of the generated names (`Random_x24init_0`, `dot_0`, `cross_0`, ...) occurs in what stays in either
  consumer.
- `src/*.slang` transpile FlexLight `5a313db` line for line, with its names, expressions, comments and order; in
  Slang's syntax, WGSL's `fn` reads `func`, `const` `static const` (`static let` would be an uninitialized private
  variable), struct members `__extern_cpp public T name;`, `f32`/`u32`/`vec3<f32>` `float`/`uint`/`float3`, and
  `ptr<function, u32>` `inout uint`, and WGSL's `select(f, t, cond)` keeps its argument order through an overload in
  `math.slang`, Slang's own being `select(cond, t, f)`. Besides that, only target plumbing,
  marked so in the source: `pcg` keeps renderer.cu's generator outside WGSL; `normalize`, `inverseSqrt` and WGSL's
  `select` lower to each consumer's own (CUDA `rnorm3df` and `rsqrtf`, WGSL's builtins, C++ the host shims of the
  CUDA ones, against which the CUDA goldens are made); and in `sampleGGXVNDF`, `T1` is FlexLight's `select` for WGSL
  but renderer.cu's ternary elsewhere, as nvcc fuses the multiply-adds after it differently without that branch, and
  `unshared` keeps Slang from reusing the earlier `1.0 - t1 * t1`, which NVIDIA's driver rounds differently.
- `-g2` keeps the statements and temporaries of the source, which Slang folds into expressions otherwise; folded,
  nvcc fused `t2` of `sampleGGXVNDF` differently.
- The GPU results were checked by building `tests/parity.cpp` once against the generated header and once against the
  baseline `renderer.cu` (OptiX stubbed on the device), and the WGSL by running `tests/wgsl.mjs` on the generated
  code and on FlexLight's shader on each GPU: Dawn's choice of adapter is local.
- Slang inlines constants and emits only types an exported function reaches, which keeps the equal constants and
  `SampleBSDF` local.
- slangc writes the prelude include as an absolute path into the installation; the `Makefile` rewrites that one
  `#include` line to the copy next to the header and renames the prelude's `Matrix` template, unused by the
  generated code, around it, which left `renderer.cu` no name for its own `Matrix`. No generated identifier is
  rewritten.
- The CUDA prelude raises warning #1444 (deprecated `ulonglong4`) under CUDA 13; harmless.

## Parity

Goldens on the grid of 288 cases (roughness 0, 0.05, 0.5, 1 × metallic 0, 1 × transparency 0, 0.5, 1 × entering,
leaving with total internal reflection and no index change × random, offset geometry normal, grazing incidence,
grazing incidence and exitance): every shared function on the case's directions, normal, albedo, roughness, IORs and
random state, `sampleGGXVNDF` also directly on the outgoing direction mirrored above the surface.

- `tests/golden-cuda.txt`: `make golden REFERENCE=<flex-cuda-pt 02d0bf1>/src/shaders` host-compiles the unmodified
  `renderer.cu` against `tests/shim` and reproduces it byte for byte.
- `tests/golden-wgsl.txt`: `make golden-wgsl WGSL_REFERENCE=<FlexLight 5a313db>/.../pathtracer-compute.wgsl`
  appends the kernel of `tests/wgsl.mjs` to the unmodified shader and runs it through Dawn, here in `ubuntu:24.04`
  with lavapipe as CI runs it. Its `pcg` columns differ from CUDA's, `hash` and `stream` agree.

Tolerance: integers (random states, hashes) exactly; floats within
`1e-5 + (1e-3 + 8 * 2^-23 / alpha^2) * |golden|`, as the GGX denominator `n_dot_h^2 (alpha^2 - 1) + 1` cancels down
to `alpha^2` at a lobe's peak.

| Run | Where | Result |
|---|---|---|
| `make test-cpu` | Slang C++ target vs CUDA goldens, CI | 288 / 288, bit-identical |
| `make test-wgsl` | Generated WGSL vs FlexLight goldens, Dawn on lavapipe (CI) / Intel Mesa (local) | 288 / 288, bit-identical / worst 0.630 of the tolerance, as the goldens are lavapipe's |
| `tests/wgsl.mjs` | Generated WGSL vs FlexLight's own shader on the same GPU: Intel Mesa, NVIDIA 615.78 | bit-identical on both |
| `make test-cuda` | Generated CUDA on the local RTX 5090 vs CUDA goldens | 288 / 288, worst 0.099 of the tolerance; bit-identical to the baseline `renderer.cu` on the same GPU |

## Identity of the consumers

Against the baselines flex-cuda-pt `02d0bf1` and FlexLight `5a313db`, `feat/flexkernels` vendoring FlexKernels
`719529b`:

- flex-cuda-pt: `make` and `make test` pass. The 9 renders of `src/test.py` (64 × 64, captured from each
  `render.render`) are bit-identical to the baseline at the same seed, RMSE 0 in all, where the baseline against itself
  at another seed (`scene.frame` from 2^20) has an RMSE of 0.653 overall (1.15, 1.19, 1.00, 0.283, 0, 0.0117, 0.0168,
  0.00324, 0.169). `renderer.cu` lost 145 lines and gained 3, the `Makefile` its two prerequisites.
- FlexLight: `bash ./build-script` passes. All 9 WGSL modules of the bundle compile in Dawn without errors and give a
  pipeline with `layout: "auto"` for every entry point (7 compute modules, ReSTIR's 10 passes included, and the depth
  and raster render pipelines), on the baseline and on the branch alike; the 8 modules besides the path tracer's are
  byte-identical. The bundle differs in the shader text and the prepend site only. `pathtracer-compute.wgsl` lost
  164 lines, `pathtracer.ts` composes the shader once for the compute pipeline and ReSTIR.
- The line-for-line transpile: the flex-cuda-pt renders stay bit-identical to `6652e76`, and the path tracer's
  composed shader (`bsdf.wgsl` and `pathtracer-compute.wgsl`) returns bit-identical results to FlexLight `5a313db`'s
  shader through Dawn on Intel and NVIDIA, which fuse multiply-adds where lavapipe does not.
- Independent verifier reviews of both diffs (call-site mapping, removed code still referenced, RNG consumption order)
  found no behavior change.

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
- `BvhTracer`: FlexLight's `traverseInstanceBVH` and `moellerTrumbore`, reading its textures; `Hit` would carry the
  instance as FlexLight's does.

## Porting order

1. Done: the identical microfacet terms and sampling, the random numbers on each target's own generator and the
   colour helpers, as **Shared** above.
2. Then the next candidates in their order below.

## Next candidates

Ranked by what they would share, with what blocks each:

1. The BSDF on top (`bsdfLobes`, `lobeThroughput`, `lobeDensity`, `sampleBSDF`, `connectBSDF`, `BSDF`, `neeDecision`,
   `G1`, `SampleBSDF`, `BSDFLobes`): the same structure, but the behaviors differ (Smith vs Schlick masking,
   Principled tint and level, diffuse dimming, albedo-colored refraction vs colorless reflection, clamped density).
   Sharing it means choosing one model and changing the other consumer, the user's decision.
2. The equal constants (`PI`, `BIAS`, `INV_PI`, `LOBE_*`, `RESTIR_*`, `RC_*`, `PATH_*`, `END_NEE`, `END_EMIT`,
   `STREAM_NEE`, `STREAM_RR`, `STREAM_SELECT`): need a generated header of named constants beside Slang's output.
3. `Selection`, `offer`, `offerShifted`, `finalize`, `Shift`: pure math once `Reservoir` has a backend-neutral
   reconnection record (`uint4`, as WGSL has it) and `Shift` leaves `renderer.h`; `offer` then draws by each target's
   `pcg`.
4. `tangentToWorldNormalMap` on a shared frame type, then `normalMapTBN` once FlexLight takes Blender's handedness.
5. `withEnd`, `wrongSide` and `partner`: the same paths with other parameters; `partner` once the pairing texture is
   read through the scene interface.
6. `faceNormal`, `smoothNormal`, `geometryOffset`: same math, CUDA's factoring; data access via `IScene`.
7. `beerLambert`: CUDA's Cycles absorption, once FlexLight's `Material` carries `absorption` and `density`.
8. `sampleLight` by importance, keeping FlexLight's point lights as a backend extra.
9. `walk` and `shift` behind `ITracer` and `IScene`; FlexLight's `lightTrace` then becomes `walk` without ReSTIR.
10. `shade`: the node program interpreter, after a union-free `Op` and a texture interface.

## Decisions made without the user

- The two BSDFs differ in behavior since "derive all material evaluation from sampleBSDF", so only their identical
  terms and sampling are shared; nothing was bent to share more.
- `pcg` lives in FlexKernels with one branch per target rather than in each consumer, so that `sampleHalfVector` and
  the normal draws can call it; each branch is its consumer's generator verbatim.
- The direct `sampleGGXVNDF` goldens view from above the surface, as `sampleHalfVector` does: below it the result is
  ill-conditioned at the `max(0, Nh.z)` clamp and the GPU's `cosf` flips it.
- The WGSL goldens are FlexLight's outputs on lavapipe, the device of CI, so that CI checks them bit for bit.
- `MAX_SAFE_INTEGER_FOR_F32` is deleted in both consumers with its only use; `xzy` stays dead in CUDA for a minimal
  diff.
