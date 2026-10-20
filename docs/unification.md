# Unifying the FlexCudaPT and FlexLight kernels

Line numbers refer to the current mains, the identity baseline: flex-cuda-pt `02d0bf1` (`cu` =
`src/shaders/renderer.cu`, `h` = `src/shaders/renderer.h`) and FlexLight `5a313db` (`wgsl` =
`src/flexlight/webgpu/shaders/pathtracer-compute.wgsl`, `shift` = `.../pathtracer-shift.wgsl`, `ts` =
`src/flexlight/webgpu/restir.ts`), before either consumed FlexKernels.

Every function, struct and constant falls in one of three classes: **1** identical or trivially unifiable (same math,
cosmetic differences), **2** diverged but unifiable (same purpose) and **3** backend-specific (traversal, data access,
bindings and entry points). Classes 1 and 2 are **Shared** in `src/pathtracer.slang`, which transpiles the FlexLight code
it replaces line for line, in its order, with its names, comments and expressions: parity to FlexLight, after compiling
and the target plumbing marked so in the source, comes first. flex-cuda-pt takes FlexLight's code where its own diverged,
so its look changes there; it only has to keep working. Class 3 stays in each consumer, with the reason. FlexLight's diff
is a deletion and the composition; flex-cuda-pt's adapts its call sites.

## Classification

### Random numbers and helpers

| Name | CUDA | WGSL | Class | Status | Reason |
|---|---|---|---|---|---|
| `hash`, `stream` | cu:43, 586 | wgsl:1854, 1860 | 1 | **Shared** | Identical |
| `Random`, `RandomSphere`, `RandomHemisphere` | cu:49-51 | wgsl:227-237 | 1 | **Shared** | Identical layouts |
| `pcg` | cu:53 | wgsl:246 | 3 | **Shared**, per target | The generators differ: CUDA advances to the hash and draws its 24 high bits, FlexLight advances the LCG state and draws the hash over `UINT_MAX`, which reaches 1. Each target keeps its consumer's exactly (`__target_switch`) |
| `normal_distribution`, `random_sphere`, `random_hemisphere` | cu:67, 76, 83 | wgsl:257, 266, 273 | 1 | **Shared** | Same math on each target's `pcg`; CUDA has no caller |
| `random` | cu:48 | – | 3 | Local | CUDA only, its draw is the CUDA branch of `pcg` |
| `Random`, `RandomSphere`, `RandomHemisphere`, `rgb_to_greyscale`, `pcg`, `normal_distribution`, `random_sphere`, `random_hemisphere`, `normalMapTBN`, `tangentToWorldNormalMap` of the rasterizer | – | `rasterizer-compute.wgsl`:226-282 (`5a313db`) | 1 | **Shared** | Identical copies; the rasterizer takes `pathtracer.wgsl` as the path tracer does |
| `trowbridgeReitz` of the rasterizer | – | `rasterizer-compute.wgsl`:424 | 1 | **Shared** | The shared one over two half vectors: called per vector, bit-identical on lavapipe, Intel and NVIDIA for 65536 pairs |
| `fresnel`, `BSDF` of the rasterizer | – | `rasterizer-compute.wgsl`:440, 481 | 3 | Local | The rasterizer's direct lighting by Schlick's Fresnel, its own model; renamed `fresnelSchlick` and `directBSDF`, as WGSL has no overloads |
| `rgb_to_greyscale`, `safeDivide` | cu:57, 748 | wgsl:242, 1944 | 1 | **Shared** | Identical outputs (`select` vs ternaries) |
| `brightest`, `tinted` | cu:59, 123 | – | 3 | Deleted | Principled specular tint and level of flex-cuda-pt's BSDF, which FlexLight's has not; they went with it |
| `PI`, `BIAS`, `INV_PI`, `MAX_SAFE_INTEGER_FOR_F32` | cu:6-9 | wgsl:20-30 | 1 | Local, inlined | Equal as `f32`, but Slang inlines constants and can't export a named one; the shared code has its own. `MAX_SAFE_INTEGER_FOR_F32` lost its only use to `normal_distribution` |
| float3 operators, `xzy`, `mix`, `sign`, `dot`, `cross`, `reflect`, `refract`, `normalize`, `length`, `wrap` | cu:12-42 | builtins | 1 | Local | WGSL and Slang builtins. For WGSL the shared code calls FlexLight's own builtins, `mix`, `sign`, `select`, `normalize`, `inverseSqrt` and `insertBits`, and its `-` of a vector through plumbing that emits them as written, where Slang would write `mix(a, b, vec3(t))`, `f32(i32(sign(x)))` and `vec3<f32>(0) - x`, positive where `x` is zero |

### BSDF

| Name | CUDA | WGSL | Class | Status | Reason |
|---|---|---|---|---|---|
| `trowbridgeReitz`, `smithG1`, `fresnel` | cu:94, 61, 104 | wgsl:691, 703, 708 | 1 | **Shared** | Identical; then D without the cancellation and floor that cut its peak off below roughness 0.22, an allowed change to both goldens |
| `G1` | cu:100 | wgsl:697 | 2, FlexLight | **Shared** | FlexLight's Schlick `k = alpha / 2`; flex-cuda-pt had the exact Smith masking |
| `sampleGGXVNDF`, `sampleCosWeightedHemisphere`, `tangentToWorld`, `worldToTangent` | cu:131, 153, 162, 172 | wgsl:726, 748, 757, 767 | 1 | **Shared** | Identical |
| `normalMapTBN`, `tangentToWorldNormalMap` | cu:184, 203 | wgsl:779, 801 | 2, FlexLight | **Shared** | FlexLight's `mat3x3<f32>` and handedness, which flips the tangent where flex-cuda-pt turned the bitangent; Slang writes the columns as `float3x3(t, b, n)` and `tbn * v` as `mul(v, tbn)`, which WGSL gets back as written. CUDA takes the prelude's `Matrix<float, 3, 3>`, named `SlangMatrix` across the header, for its own `Matrix` |
| `BSDF`, `SampleBSDF`, `BSDFLobes`, `sampleHalfVector`, `bsdfLobes`, `lobeThroughput`, `lobeDensity`, `sampleBSDF`, `connectBSDF` | cu:438, 210, 221, 235, 246, 278, 325, 360, 411 | wgsl:807-1032 | 2, FlexLight | **Shared** | FlexLight's plain Fresnel, undimmed diffuse and clamped density on its `Material`, whose albedo tints every surface interaction, the diffuse, metallic reflection and refraction, its absorption left to `beerLambert`; flex-cuda-pt's tint, level and Smith masking go |
| `neeDecision` | cu:515 | wgsl:1356 | 2, FlexLight | **Shared** | Plain Fresnel |
| `neeBSDF` | `lightBSDF` cu:998 (`2782758`) | `skyBSDF` wgsl:1195 (`d20d420`) | 2, FlexLight | **Shared** | FlexLight's balance heuristic per lobe, over the density of the sample, on the side the consumer's `wrongSide` selects; flex-cuda-pt's power heuristic as an option, in FlexLight's form |
| `straightThrough` | inline in `sampleLight` cu:960 (`2782758`) | – | 2 | **Shared** | Shadow rays passing straight through equal IORs, as `sampleBSDF`'s refraction lobe carries them on average; flex-cuda-pt's lacked the share of metallic reflection, `1 - F`. FlexLight's shadow rays stop at every surface |
| `Material` (FlexLight) | – | wgsl:104, `rasterizer-compute.wgsl`:93 | 3 | Local | Laid out by the TypeScript upload and read from bindings: the shared code declares it `__target_intrinsic(wgsl, "Material")`, as FlexLight's own, and `__target_intrinsic(cuda, "BSDFMaterial")`, which flex-cuda-pt's `renderer.h` declares with the same fields and `walk` fills from its `Surface` |
| `LOBE_DIFFUSE`, `LOBE_REFRACT` | cu:207 | wgsl:1746 | 1 | Local, inlined | Equal, constants (see `PI`) |

### Surfaces, lights and media

| Name | CUDA | WGSL | Class | Status | Reason |
|---|---|---|---|---|---|
| `Surface` (CUDA) | h:13 | – | 3 | Local | Program output, with tint, level, coverage and the medium |
| `Material` (CUDA) | h:18 | – | 3 | Local | Light power and program per triangle |
| `Surface` (FlexLight) | – | wgsl:1243 | 3 | Local | Hit record (normals, offset, material, skip) |
| `Op`, op enum, `logarithm`, `divide`, `texel`, `shade` | h:9-11, cu:451-500 | `textureSample`, `surfaceAt` wgsl:181, 1253 | 3 | Local | The Blender node interpreter has no counterpart: FlexLight's materials are fixed texture slots, `Op`'s union has none in Slang, and texels are flat pointers vs texture atlases |
| `beerLambert` | cu:510 | wgsl:1348 | 2, FlexLight | **Shared** | FlexLight's on an absorption color, which FlexLight's `Material` gained, where it took the instance's albedo from `instance_material`; flex-cuda-pt's goes; each consumer reads it at its call site |
| `faceNormal`, `smoothNormal`, `geometryOffset`, `hitPosition` | cu:605-623 | inline in `surfaceAt`, wgsl:1881 | 3 | Local | Data access: flat pointers vs instanced textures |
| `LightBounds`, `importance`, `cosSubClamped`, `sinSubClamped`, `sine`, `solidAngle`, `pickChild`, `childShare`, `powerHeuristic` | h:38, cu:867-899, 995 and the steps of `sampleLight` and `lightPdf` (`bd5216f`) | – | 1 | **Shared** | renderer.cu's light tree, transpiled, for FlexLight's to come; `LightBounds` holds a node's emitters alone, each consumer keeps its tree, and is `__target_intrinsic(cuda)` renderer.h's `LightNode`. Each consumer loops down its own nodes one `pickChild` or `childShare` step at a time |
| `sphereDensity`, `sampleSphere` | – | – | 1 | **Shared** | Cone sampling toward FlexLight's point lights as spheres and its density in solid angle, so that hits on them can be weighted against light sampling (pbrt-v4's Sphere::Sample) |
| `sampleLight`, `lightPdf` | cu:915, 980 (`bd5216f`) | `Light`, `sampleLight`, `occluded` wgsl:113, 1054, 1154 | 3 | Local | The visibility test traverses, the nodes are read from each consumer's own data |
| `pointLightRadiance` | – | wgsl:1238 | 1 | **Shared** | The math of `calculatePointLightContrib`, `color * intensity / (PI * radius * radius)`: corrected from 5a313db's extra factor of four at the user's direction so light hits agree with direct lighting; the light lookup stays in FlexLight |
| `LightSample`, `NEESample`, `reservoirSample`, `calculatePointLightContrib`, `SamplePreCalc`, `SampledColor`, `lightTrace` | – | wgsl:1033-1364 | 3 | Local | FlexLight only; `calculatePointLightContrib` reads its light and calls `pointLightRadiance` |
| `environment` | cu:661 | wgsl:1931 | 3 | Local | World shader program vs equirectangular map or ambient |
| `env_map_sample`, `environmentMapped`, `environmentPdf`, `searchCDF`, `skyRadiance`, `SkySample`, `sampleSky`, `escapeWeight` | – | wgsl:1529-1626 | 3 | Local | FlexLight's environment NEE |

### Traversal, ReSTIR and entry points

| Name | CUDA | WGSL | Class | Status | Reason |
|---|---|---|---|---|---|
| `Hit`, `Ray`, `Intersect`, `traverse` | h:25, cu:595 | wgsl:99-126, `traverseInstanceBVH` 469 | 3 | Local | `optixTraverse` vs the software BVH (wgsl:284-628) |
| `Camera`, `Settings`, `Scene`, `Transform`, uniforms | h:5, 44, 51 | wgsl:34-52, shift:7-22 | 3 | Local | Bindings |
| `Reservoir`, `Shift`, `Selection` | h:27, 41, cu:565 | wgsl:1810, 1842, 1847 | 1 | **Shared** | FlexLight's; `Reservoir` and `Shift` `__target_intrinsic(cuda)`, as the host sizes its buffers by `renderer.h`'s, whose `rc` is a `Hit`: the shared code only copies `rc` and never constructs a `Reservoir` |
| `offer`, `offerShifted`, `finalize`, `withEnd` | cu:753-782 | wgsl:1949-1980 | 1 | **Shared** | FlexLight's: `offer` draws through `pcg`, renderer.cu's `random` on CUDA, `withEnd` inserts its bits, which every candidate leaves clear for CUDA's OR |
| MIS weights of temporal and paired spatial reuse | inline in `__raygen__temporal`, `__raygen__spatial` | inline in `restir_temporal`, `restir_spatial` | 1 | Local | Identical but the confidence cap, `mix` vs `a + (b - a) * t`, yet written inline in both entry points: functions of their own would change FlexLight's structure |
| `Domain`, `Vertex` | cu:569-579 | wgsl:1827-1840 | 3 | Local | Hold `Hit`; WGSL's `Vertex` adds `inside` |
| `extractBits` | cu:590 | builtin | 1 | Local | WGSL builtin |
| `wrongSide` | cu:639 | wgsl:1988 | 3 | Local | The incoming direction's side of the face vs FlexLight's `inside` state of the path |
| `vertexEta` | inline in `walk` | wgsl:1939 | 1 | Local | Not a CUDA function |
| `RESTIR_*`, `END_NEE`, `END_EMIT`, `RC_*`, `PATH_*` (but `PATH_INSIDE`), `STREAM_NEE`, `STREAM_RR`, `STREAM_SELECT` | cu:529-562 | wgsl:1738-1777 | 1 | Local, inlined | Equal, constants (see `PI`). `END_ENV` is 2 vs 3, `STREAM_JITTER`/`STREAM_COVERAGE` vs `STREAM_SPHERE`/`STREAM_SKY` |
| `walk`, `shift`, `pixelDomain` | cu:793, 1046, 645 | wgsl:1996, 2335, `currentDomain`... 1892-1923 | 3 | Local | Behind `ITracer` and a scene interface, see below |
| `project`, `previousValid`, `temporalNeighbor`, `partner` | cu:1059-1094 | wgsl:2297-2323 | 3 | Local | Camera basis vs view matrix; pairing `char2*` vs `texture_2d_array<i32>` |
| `loadReservoir`, `storeReservoir`, `ShiftQueue`, `sameDomain`, `ShiftJob`, ... `queuedShift` | – | wgsl:1802, 1864-1873, 2399-2521 | 3 | Local | Reservoir textures and shift binning of FlexLight |
| `__raygen__initial`, `temporal`, `shift`, `spatial`, `duplicates` | cu:1113-1230 | `compute`, `restir_*` wgsl:1635, 2346-2672 | 3 | Local | Entry points |
| `compute` (shift pass), `pairingTexture`, `ReSTIR` | – | shift:49, ts:34, 64 | 3 | Local | Accumulation reprojection, host side |

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

- Slang 2026.19, fetched into `.deps/slang-2026.19` by the `Makefile`, so that commits generated again by the
  deployment each take their own. `src/pathtracer.slang` holds all shared code and is compiled once per target into
  one output each, `pathtracer.cuh` for CUDA and HIP, `pathtracer.wgsl` and, for the parity tests, `pathtracer.cpp`;
  every consumer shader takes the one file of its target.
- Stable names: exported functions carry `[CudaDeviceExport]`, which keeps them alive and unmangled for CUDA, WGSL
  and C++ alike; structs and their fields carry `__extern_cpp`. Everything else gets Slang's `_0` suffix (CUDA
  `static`). None of the generated names (`Random_x24init_0`, `dot_0`, `cross_0`, ...) occurs in what stays in either
  consumer.
- `src/pathtracer.slang` transpiles FlexLight `5a313db` line for line, in the order of its file, with its names, expressions, comments and order; in
  Slang's syntax, WGSL's `fn` reads `func`, `const` `static const` (`static let` would be an uninitialized private
  variable), struct members `__extern_cpp public T name;`, `f32`/`u32`/`vec3<f32>` `float`/`uint`/`float3`, and
  `ptr<function, u32>` `inout uint`, and WGSL's `select(f, t, cond)` keeps its argument order through an overload in
  `pathtracer.slang`, Slang's own being `select(cond, t, f)`. Besides that, only target plumbing,
  marked so in the source: `pcg` keeps renderer.cu's generator outside WGSL; `normalize`, `inverseSqrt` and WGSL's
  `select` lower to each consumer's own (CUDA `rnorm3df` and `rsqrtf`, WGSL's builtins, C++ the host shims of the
  CUDA ones, against which the CUDA goldens are made); and in `sampleGGXVNDF`, `T1` is FlexLight's `select` for WGSL
  but renderer.cu's ternary elsewhere, as nvcc fuses the multiply-adds after it differently without that branch, and
  `unshared` keeps Slang from reusing the earlier `1.0 - t1 * t1`, which NVIDIA's driver rounds differently.
- Further target plumbing, marked so: WGSL's `mix`, `sign` and `insertBits` emit FlexLight's builtin calls as written,
  elsewhere their WGSL definitions, and `negate(x)` its `-x` of a vector, which keeps the sign of a zero; `select` has a scalar overload in WGSL's argument order; FlexLight's
  `mat3x3<f32>(t, b, n)` of columns reads `float3x3(t, b, n)` and `tbn * v` reads `mul(v, tbn)`, as Slang keeps
  matrices by rows, and WGSL gets both back as written; FlexLight's `Material` is `__target_intrinsic` for WGSL and
  CUDA, `BSDFMaterial` there, and so are flex-cuda-pt's `Reservoir` and `Shift`, by which its host sizes buffers, while
  their `__extern_cpp` fields keep the consumers' names. The shared code never constructs a `Reservoir`, as the struct
  Slang knows has FlexLight's `uint4` reconnection record, which CUDA's holds as a `Hit`.
- `-g2` keeps the statements and temporaries of the source, which Slang folds into expressions otherwise; folded,
  nvcc fused `t2` of `sampleGGXVNDF` differently.
- The GPU results were checked by building `tests/parity.cpp` once against the generated header and once against the
  baseline `renderer.cu` (OptiX stubbed on the device), and the WGSL by running `tests/wgsl.mjs` on the generated
  code and on FlexLight's shader on each GPU: Dawn's choice of adapter is local.
- Slang inlines constants and emits only types an exported function reaches, which keeps the equal constants local; the
  shared code has its own.
- slangc writes the prelude include as an absolute path into the installation; the `Makefile` rewrites that one
  `#include` line to the copy next to the header and renames the prelude's `Matrix` template, unused by the
  generated code takes for FlexLight's `mat3x3`, `SlangMatrix` across the header, which leaves `renderer.cu` its own
  `Matrix`. No generated identifier is rewritten.
- The CUDA prelude raises warning #1444 (deprecated `ulonglong4`) under CUDA 13; harmless.

## Parity

Goldens on the grid of 288 cases (roughness 0, 0.05, 0.5, 1 × metallic 0, 1 × transparency 0, 0.5, 1 × entering,
leaving with total internal reflection and no index change × random, offset geometry normal, grazing incidence,
grazing incidence and exitance): every shared function on the case's directions, normal, albedo, roughness, IORs and
random state, `sampleGGXVNDF` also directly on the outgoing direction mirrored above the surface, and on the case's
`Material` FlexLight's BSDF through the half vector of its directions, each lobe's throughput where `sampleBSDF` can
choose it toward its side and density, `sampleBSDF`, `connectBSDF` per lobe weighted by its density, `BSDF`,
`neeDecision`, `neeBSDF` by each heuristic against a density of 0.5 plus the transparency, the normal map of the
triangle of its directions, two reservoirs resampled by their shifts, `beerLambert` over the sum of the IORs,
`straightThrough` along the incoming direction, two light tree nodes of the case picked toward a point of it, a
triangle's density in solid angle, the power heuristic against a density of the case and against none and a sphere of
the case sampled from its incoming direction, from inside at its larger radii.

`pointLightRadiance` is checked separately on every case in C++, CUDA and WGSL: integrating its radiance over a
diffuse sphere must recover `4 * PI * intensity * color`, without changing the reference golden columns.

- `tests/golden-cuda.txt`: `make golden REFERENCE=<flex-cuda-pt 02d0bf1>/src/shaders` host-compiles the unmodified
  `renderer.cu` against `tests/shim`, its D without cancellation or BIAS, and reproduces it byte for byte: the functions
  both consumers had alike.
- `tests/golden-wgsl.txt`: `make golden-wgsl WGSL_REFERENCE=<FlexLight 5a313db>/.../pathtracer-compute.wgsl`
  appends the kernel of `tests/wgsl.mjs` with `--flexlight` to the reference shader and runs it through Dawn, here in
  `ubuntu:24.04` with lavapipe as CI runs it: every column. For the generated code the kernel prepends FlexLight's
  `Material`, which FlexLight's shader declares, and calls the same functions. Its `pcg` columns differ from CUDA's,
  `hash` and `stream` agree. The C++ and CUDA targets are compared against it for what only FlexLight had, but the
  columns drawing random numbers, which each target draws from its own generator: `sampleBSDF`, the diffuse
  `connectBSDF`, `BSDF` and what the resampling chooses. Since the albedo stopped standing in for absorption, the
  throughputs of refraction and reflection in `lobeThroughput`, `sampleBSDF`, `connectBSDF` and `BSDF` and `beerLambert`,
  and since D lost its cancellation and floor, D and the densities, are 5a313db's on lavapipe with only the allowed
  changes applied by the harness: refraction times the albedo, reflection using `F`, its original `beerLambert` reading
  the absorption color passed to it, and D over `(1 - n_dot_h) (1 + n_dot_h) + alpha^2 n_dot_h^2` without BIAS; every
  other column is 5a313db's, word for word.
  The C++ and CUDA targets leave out `neeBSDF` where it draws, toward the side of a diffuse lobe; the golden of its power
  heuristic is flex-cuda-pt's `lightBSDF` of `2782758` on FlexLight's `connectBSDF`, over the density.
  `straightThrough`'s is FlexLight's refraction throughput times its probability through the normal at equal IORs.
  The light tree's are renderer.cu's (`bd5216f`), transcribed into the kernel, whose generated CUDA returned the same
  words as renderer.cu's own on a million random nodes, points and picks, with and without `--use_fast_math`.
  The sphere's are pbrt-v4's formulas written out in the kernel, `1 - cos` of the cone by its square root.

Tolerance: integers (random states, hashes, lobes, decisions, seeds) exactly; floats within
`1e-5 + (1e-3 + 8 * 2^-23 / alpha^2) * |golden|`, as the GGX denominator, `alpha^2` at a lobe's peak, turns rounding
of `n_dot_h` there into relative errors of D by `2^-23 / alpha^2`, and NaN where the golden has it: the normalized
refraction under total internal reflection.

| Run | Where | Result |
|---|---|---|
| `make test-cpu` | Slang C++ target vs CUDA goldens / vs FlexLight goldens, CI | 288 / 288, bit-identical / worst 0.013 of the tolerance |
| `make test-wgsl` | Generated WGSL vs FlexLight goldens, Dawn on lavapipe (CI) | 288 / 288, bit-identical |
| `make test-wgsl` | The same on the local Intel Mesa | 1 of 288 cases off: a component of `sampleBSDF`'s direction at 1.46 of the tolerance, as FlexLight's own shader on that device |
| `tests/wgsl.mjs` | Generated WGSL vs FlexLight's own shader `5a313db` on the same device: lavapipe, Intel Mesa, NVIDIA 615.78 | every column of all 288 cases bit-identical on each, the random draws included |
| `make test-cuda` | Generated CUDA on the local RTX 5090 vs CUDA goldens / vs FlexLight goldens | 288 / 288, worst 0.099 / 0.016 of the tolerance |
| `make test-hip` | hipcc 7.2.4 compile only, CI, with `tests/hip.cpp` declaring what `renderer.h` would | compiles |

## Identity of the consumers

Against the baselines flex-cuda-pt `6652e76` and FlexLight `5a313db`, `feat/flexkernels` vendoring FlexKernels
`719529b`. flex-cuda-pt's `main` moved from `02d0bf1` during the port (readback through a shared in-memory file,
`--use_fast_math`), with `renderer.cu` and `renderer.h` unchanged, so the line numbers above and the CUDA goldens still
hold; the branch was rebased onto it and checked against both.

- flex-cuda-pt: `make` and `make test` pass. The 9 renders of `src/test.py` (64 × 64, captured from each
  `render.render`) are bit-identical to the baseline at the same seed, RMSE 0 in all, against both `02d0bf1` and
  `6652e76`, where the baseline against itself at another seed (`scene.frame` from 2^20) has an RMSE of 0.633 overall
  (1.15, 1.11, 0.973, 0.286, 0, 0.0117, 0.0168, 0.00323, 0.169; 0.653 at `02d0bf1`). `renderer.cu` lost 145 lines
  and gained 3, the `Makefile` its two prerequisites.
- FlexLight: `bash ./build-script` passes. All 9 WGSL modules of the bundle compile in Dawn without errors and give a
  pipeline with `layout: "auto"` for every entry point (7 compute modules, ReSTIR's 10 passes included, and the depth
  and raster render pipelines), on the baseline and on the branch alike; the 8 modules besides the path tracer's are
  byte-identical. The bundle differs in the shader text and the prepend site only. `pathtracer-compute.wgsl` lost
  164 lines, `pathtracer.ts` composes the shader once for the compute pipeline and ReSTIR.
- FlexLight's rasterizer, against its `main` of the time with FlexKernels `b489f9b`: the build passes, all 9 WGSL
  modules validate as above with the rasterizer's composed of `random.wgsl` and `rasterizer-compute.wgsl`, the
  bundle differs in the shader text and its prepend site only, and `pcg`, `normal_distribution`, `random_sphere`,
  `random_hemisphere` and `rgb_to_greyscale` of the composed shader return bit-identical words to the old one's
  through Dawn on the 288 inputs. `rasterizer-compute.wgsl` lost 58 lines.
- The line-for-line transpile: the flex-cuda-pt renders stay bit-identical to `6652e76`, and the path tracer's
  composed shader (`bsdf.wgsl` and `pathtracer-compute.wgsl`) and the rasterizer's (`random.wgsl` and
  `rasterizer-compute.wgsl`) return bit-identical results to FlexLight `5a313db`'s shaders through Dawn on Intel and
  NVIDIA, which fuse multiply-adds where lavapipe does not.
- Independent verifier reviews of both diffs (call-site mapping, removed code still referenced, RNG consumption order)
  found no behavior change.

- Both consumers: a commit per FlexKernels step, each vendoring that step's kernels and built.
- FlexLight: `bash ./build-script` passes and all 9 WGSL modules validate as above. Its composed shader,
  `pathtracer.wgsl` before `pathtracer-compute.wgsl`, returns words bit-identical to `5a313db`'s shader for every column
  of the parity kernel on Intel and NVIDIA. `pathtracer-compute.wgsl` lost 327 lines and gained none since the single
  source; `rasterizer-compute.wgsl` lost 43 and gained 9 (the per-vector `trowbridgeReitz` and two renames).
- flex-cuda-pt: `make` and `make test` pass, the test expecting FlexLight's BSDF: reflection untinted at any specular
  tint and level, the diffuse beside the specular (a white furnace of 1.048), FlexLight's grazing specular albedo
  (0.0735 where Cycles has 0.118). `walk` fills a `BSDFMaterial` from its `Surface`, `shade` takes FlexLight's matrix.
  It renders with FlexLight's BSDF, normal map and next event estimation choice, by design not as before: the
  replayed renders part from the single source by an RMSE of 0.47, where two seeds part by 0.13. `renderer.cu` lost
  341 lines and gained 21, `renderer.h` gained `BSDFMaterial`.

## Deployment

Every push to `main` builds and tests the kernels, then the `deploy` job, one at a time over both consumers, runs
`ci/deploy.sh` in a checkout of the consumer's `main` made with its write deploy key (`FLEX_CUDA_PT_DEPLOY_KEY`,
`FLEXLIGHT_DEPLOY_KEY`; pushes with the default token would start none of the consumer's workflows): for each
FlexKernels commit to `src/` or the `Makefile` since the consumer's `VERSION`, it generates the kernels in a worktree of
that commit, replaces the vendored directory with them, writes `VERSION` and, if the kernels changed, builds the
consumer with its own toolchain and commands and commits with that commit's message, author and dates, so that the
consumer's history follows the commit conventions as FlexKernels' does: commits leaving its kernels as they were
(documentation, CI, tests, the other target) pass nothing on. It pushes them together, rebasing once if `main` moved.
The consumer's own workflows then release the extension and deploy the website.

Rehearsed locally against bare clones of both consumers' `main`, from a scratch clone of FlexKernels with a change
to the Makefile that leaves the kernels as they were, a kernel change and a documentation change on top: each consumer
got one commit, the kernel change's, with its subject, author and dates, and was built with it first; the Makefile's
change passed nothing on, and the documentation was never built. A second deploy committed nothing, and a push racing
the deploy was rebased onto. From a fresh clone without `.deps`, as CI deploys, onto a flex-cuda-pt
`main` that cannot build the kernels: Slang was fetched once and the deploy stopped with nothing committed or pushed.

## HIP

Slang 2026.19 has no HIP target, and its CUDA prelude does not build under hipcc (170 errors: PTX asm for surface
objects, `cudaSurfaceObject_t`, 32-bit warp masks where HIP wants 64, `bool2`/`bool4`, `__ldg` overloads). The
generated code itself does: `src/hip-prelude.h` provides the few wrappers it uses (`F32_*`, scalar `make_float3`,
`uint`, and the `Matrix` of FlexLight's `mat3x3`; `rsqrtf` and `rnorm3df` are HIP's), and `build/hip` pairs it with the
same header, which leaves `BSDFMaterial`, `Reservoir` and `Shift` to the renderer as CUDA's does: `tests/hip.cpp`
declares them as `renderer.h` does. CI compiles that in
`rocm/dev-ubuntu-24.04:7.2.4`. A HIP backend still needs HIPRT traversal and a HIP build of the renderer.

## Vulkan

flex-cuda-pt's Vulkan renderer is Slang itself, so it imports the shared code instead of including generated code:
`build/cuda/pathtracer.slang-module` is the module serialized, which only the Slang version that wrote it loads, next to
the CUDA header, with which the deployment vendors it. It is compiled without debug information, which would embed the
source's absolute path, and from the relative one, so that it is the same wherever it is built. Its structs are the
shared code's own, `Reservoir`'s reconnection record FlexLight's `uint4`. `tests/vulkan.slang` imports it into a
compute shader compiled to SPIR-V, calling what the renderer calls.

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

1. Done: the identical microfacet terms and sampling, the random numbers on each target's own generator and the
   colour helpers.
2. Done: one source and one output per target; then FlexLight's `G1` and normal map, lobe terms, BSDF sampling,
   connections and evaluation, choice of next event estimation, reservoirs and resampling, each a FlexKernels commit
   followed by one per consumer.
3. Then the next candidates in their order below.

## Next candidates

Ranked by what they would share, with what blocks each:

1. The equal constants (`PI`, `BIAS`, `INV_PI`, `LOBE_*`, `RESTIR_*`, `RC_*`, `PATH_*`, `END_NEE`, `END_EMIT`,
   `STREAM_NEE`, `STREAM_RR`, `STREAM_SELECT`): need a generated header of named constants beside Slang's output.
2. `faceNormal`, `smoothNormal`, `geometryOffset`: same math; data access via `IScene`.
3. `wrongSide` and `partner`: the same tests with other parameters, after the scene interface.
4. `sampleLight` by importance, after FlexLight builds and binds a light BVH.
5. `walk` and `shift` behind `ITracer` and `IScene`; FlexLight's `lightTrace` then becomes `walk` without ReSTIR.
6. `shade`: the node program interpreter, after a union-free `Op`, a texture interface and FlexLight's materials as
   programs.

## Decisions made without the user

- At the user's direction FlexLight's code is the reference: the shared code is its transpile, and flex-cuda-pt takes
  its BSDF, normal map, `G1` and choice of next event estimation, losing its Principled specular tint and level and
  Smith masking.
- FlexLight's `Material` stays its own, declared once for the upload; flex-cuda-pt names the same fields
  `BSDFMaterial`, as its `Material` is its per-triangle record.
- The MIS weights of reuse stay in the consumers as FlexLight writes them.
- `pcg` lives in FlexKernels with one branch per target rather than in each consumer, so that `sampleHalfVector` and
  the normal draws can call it; each branch is its consumer's generator verbatim.
- The direct `sampleGGXVNDF` goldens view from above the surface, as `sampleHalfVector` does: below it the result is
  ill-conditioned at the `max(0, Nh.z)` clamp and the GPU's `cosf` flips it.
- The WGSL goldens are FlexLight's outputs on lavapipe, the device of CI, so that CI checks them bit for bit.
- `MAX_SAFE_INTEGER_FOR_F32` is deleted in both consumers with its only use; `xzy` stays dead in CUDA for a minimal
  diff.
- The GitHub repository starts with `main` at `5f244b9`, the last commit without a workflow, so that a pull request
  can target it and runs only the build; `main` then fast-forwards to the reviewed branch.
- FlexLight's rasterizer takes `pathtracer.wgsl` like the path tracer, through a second composition site in
  `rasterizer.ts`. Its `trowbridgeReitz` of two half vectors calls the shared one per vector; its own Schlick
  `fresnel` and direct lighting `BSDF`, a model of their own, are renamed `fresnelSchlick` and `directBSDF` to leave
  the shared names free.
