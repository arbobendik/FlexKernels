// Evaluates the shared functions of a WGSL source, the generated one or, with --flexlight, FlexLight's unmodified
// pathtracer-compute.wgsl for its goldens, on the inputs of each golden line through Dawn, the kernel appended as
// FlexLight prepends the shared code, and prints them with its outputs in the golden format. The generated code takes
// FlexLight's Material, which FlexLight's shader declares. Usage: node wgsl.mjs shader.wgsl [--flexlight] < golden.txt
import { readFileSync } from "node:fs";
import { create, globals } from "webgpu";

const FLEXLIGHT = process.argv.includes("--flexlight");
const OUTPUTS = 143;
// As pathtracer-compute.wgsl declares it
const MATERIAL = /* wgsl */ `
struct Material {
    albedo: vec3<f32>,
    emissive: vec3<f32>,
    roughness: f32,
    metallic: f32,
    transmission: f32,
    ior: f32,
    absorption: vec3<f32>
};
`;
// The light tree of flex-cuda-pt's renderer.cu, as it transpiles it, for the goldens of what FlexLight had none of
const LIGHT_TREE = /* wgsl */ `
struct LightBounds { low: vec3<f32>, high: vec3<f32>, w: vec3<f32>, phi: f32, cos_theta_o: f32 }
fn parity_cosSubClamped(sin_a: f32, cos_a: f32, sin_b: f32, cos_b: f32) -> f32 {
    if (cos_a > cos_b) { return 1.0; }
    return cos_a * cos_b + sin_a * sin_b;
}
fn parity_sinSubClamped(sin_a: f32, cos_a: f32, sin_b: f32, cos_b: f32) -> f32 {
    if (cos_a > cos_b) { return 0.0; }
    return sin_a * cos_b - cos_a * sin_b;
}
fn parity_sine(c: f32) -> f32 { return sqrt(max(1.0 - c * c, 0.0)); }
fn parity_importance(node: LightBounds, p: vec3<f32>, normal: vec3<f32>) -> f32 {
    let center = (node.low + node.high) * 0.5;
    let diagonal = node.high - node.low;
    let wi = normalize(p - center);
    let d2 = dot(p - center, p - center);
    let r2 = dot(diagonal, diagonal) / 4.0;
    let cos_theta_w = abs(dot(node.w, wi));
    let sin_theta_o = parity_sine(node.cos_theta_o);
    var cos_theta_b = -1.0;
    if (!(d2 < r2)) { cos_theta_b = sqrt(max(1.0 - r2 / d2, 0.0)); }
    let sin_theta_b = parity_sine(cos_theta_b);
    let cos_theta_x = parity_cosSubClamped(parity_sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
    let sin_theta_x = parity_sinSubClamped(parity_sine(cos_theta_w), cos_theta_w, sin_theta_o, node.cos_theta_o);
    let cos_theta_p = parity_cosSubClamped(sin_theta_x, cos_theta_x, sin_theta_b, cos_theta_b);
    if (cos_theta_p <= 0.0) { return 0.0; }
    let cos_theta_i = - dot(wi, normal);
    var facing = 1.0;
    if (dot(normal, normal) != 0.0) {
        facing = parity_cosSubClamped(parity_sine(cos_theta_i), cos_theta_i, sin_theta_b, cos_theta_b);
    }
    return max(node.phi * cos_theta_p / max(d2, length(diagonal) / 2.0) * facing, 0.0);
}
`;
const KERNEL = /* wgsl */ `
struct ParityCase { v: array<f32, 20>, random_state: u32 }
@group(0) @binding(0) var<storage, read> parity_cases: array<ParityCase>;
@group(0) @binding(1) var<storage, read_write> parity_results: array<array<u32, ${OUTPUTS}>>;

fn parity_put(r: ptr<function, array<u32, ${OUTPUTS}>>, i: u32, x: vec3<f32>) {
    (*r)[i] = bitcast<u32>(x.x);
    (*r)[i + 1u] = bitcast<u32>(x.y);
    (*r)[i + 2u] = bitcast<u32>(x.z);
}

@compute @workgroup_size(64)
fn parity(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= arrayLength(&parity_cases)) {
        return;
    }
    let v = parity_cases[id.x].v;
    let random_state = parity_cases[id.x].random_state;
    let in_dir = vec3<f32>(v[0], v[1], v[2]);
    let out_dir = vec3<f32>(v[3], v[4], v[5]);
    let n = vec3<f32>(v[6], v[7], v[8]);
    let albedo = vec3<f32>(v[12], v[13], v[14]);
    let alpha = v[16] * v[16];
    let n_i = n * sign(dot(n, - in_dir));
    var r: array<u32, ${OUTPUTS}>;
    let p = pcg(random_state);
    r[0] = hash(random_state);
    r[1] = stream(random_state, 64u);
    r[2] = p.state;
    r[3] = bitcast<u32>(p.value);
    r[4] = bitcast<u32>(rgb_to_greyscale(albedo));
    r[5] = bitcast<u32>(smithG1(alpha, abs(dot(n, in_dir))));
    r[6] = bitcast<u32>(trowbridgeReitz(alpha, abs(dot(n, out_dir))));
    r[7] = bitcast<u32>(fresnel(abs(dot(n, in_dir)), v[18], v[19]));
    var h_state = random_state;
    let h = sampleHalfVector(- in_dir, n_i, alpha, &h_state);
    r[8] = h_state;
    parity_put(&r, 9u, h);
    parity_put(&r, 12u, sampleCosWeightedHemisphere(albedo.x, albedo.y));
    parity_put(&r, 15u, tangentToWorld(out_dir, n));
    parity_put(&r, 18u, worldToTangent(out_dir, n));
    parity_put(&r, 21u, sampleGGXVNDF(vec3<f32>(out_dir.xy, abs(out_dir.z)), alpha, albedo.x, albedo.z));
    parity_put(&r, 24u, safeDivide(albedo, vec3<f32>(v[15], v[17], v[16])));
    let normal = normal_distribution(random_state);
    let sphere = random_sphere(random_state);
    let hemisphere = random_hemisphere(random_state, n);
    r[27] = normal.state;
    r[28] = bitcast<u32>(normal.value);
    r[29] = sphere.state;
    parity_put(&r, 30u, sphere.value);
    r[33] = hemisphere.state;
    parity_put(&r, 34u, hemisphere.value);
    // The normal map of the triangle of the case's directions, with UVs of positive area
    r[37] = bitcast<u32>(G1(alpha, abs(dot(n, in_dir))));
    let uv = albedo.xy;
    parity_put(&r, 38u, tangentToWorldNormalMap(out_dir, normalMapTBN(in_dir, out_dir, vec3<f32>(v[9], v[10], v[11]), uv,
        vec2<f32>(uv.x + 0.5, uv.y + 0.1 * albedo.z), vec2<f32>(uv.x + 0.2 * albedo.x, uv.y + 0.6), n)));
    // The material of the case and the BSDF on it through the half vector of its directions
    let material = Material(albedo, vec3<f32>(0.0), v[16], v[15], v[17], max(v[18], v[19])${FLEXLIGHT ? "" : ", vec3<f32>(0.0)"});
    let ggx_n = normalize(- in_dir + out_dir);
    let lobes = bsdfLobes(in_dir, - in_dir, n_i, ggx_n, material, v[18], v[19]);
    r[41] = bitcast<u32>(lobes.v_dot_h);
    r[42] = bitcast<u32>(lobes.n_dot_h);
    parity_put(&r, 43u, lobes.refracted);
    parity_put(&r, 46u, lobes.F);
    r[49] = bitcast<u32>(lobes.F_greyscale);
    r[50] = bitcast<u32>(lobes.reflect_weight);
    r[51] = bitcast<u32>(lobes.diffuse_weight);
    r[52] = bitcast<u32>(lobes.refract_weight);
    r[53] = bitcast<u32>(lobes.p_diffuse);
    r[54] = bitcast<u32>(lobes.p_reflect);
    r[55] = bitcast<u32>(lobes.p_refract);
    // Each lobe sampleBSDF can choose, toward its side
    var p_lobe = array<f32, 3>(lobes.p_diffuse, lobes.p_refract, lobes.p_reflect);
    for (var lobe = 0u; lobe < 3u; lobe++) {
        let side = select(dot(n_i, out_dir) > 0.0, dot(n_i, out_dir) < 0.0, lobe == 1u);
        var throughput = vec3<f32>(0.0);
        if (p_lobe[lobe] > 1e-6 && side) {
            throughput = lobeThroughput(out_dir, n_i, alpha, material, lobes, lobe);
        }
        parity_put(&r, 56u + 4u * lobe, throughput);
        r[59u + 4u * lobe] = bitcast<u32>(lobeDensity(dot(n_i, out_dir), dot(out_dir, ggx_n), abs(dot(n, in_dir)), alpha,
            lobes, v[18], v[19], lobe));
    }
    let sample = sampleBSDF(in_dir, n, material, v[18], v[19], random_state, vec2<f32>(0.0));
    parity_put(&r, 68u, sample.unit_direction);
    parity_put(&r, 71u, sample.throughput);
    r[74] = sample.random_state;
    r[75] = u32(sample.refracted);
    r[76] = sample.lobe;
    r[77] = bitcast<u32>(sample.pdf);
    // As BSDF weighs them, the throughput of a direction of density about zero is any
    for (var lobe = 0u; lobe < 3u; lobe++) {
        let connected = connectBSDF(in_dir, out_dir, n, material, v[18], v[19], lobe, random_state);
        parity_put(&r, 78u + 4u * lobe, connected.throughput * connected.pdf);
        r[81u + 4u * lobe] = bitcast<u32>(connected.pdf);
    }
    parity_put(&r, 90u, BSDF(in_dir, out_dir, n, vec3<f32>(v[9], v[10], v[11]), material, v[18], v[19], random_state));
    r[93] = u32(${FLEXLIGHT ? "material.roughness > 0.0 || (material.metallic < 1.0 && material.transmission < 1.0)"
        : "samplesLights(material)"});
    // Two samples resampled by their shifts with MIS weights, as the reuse passes do
    var a = Reservoir();
    a.seed = random_state;
    a.f = albedo;
    a.w = 0.5 + v[15];
    a.jac = 2.0;
    var b = Reservoir();
    b.seed = hash(random_state);
    b.f = albedo.yzx;
    b.w = 1.5;
    b.jac = 0.25 + v[16];
    var sel = Selection();
    sel.random_state = random_state;
    offerShifted(&sel, a, Shift(albedo, 1.0), 0.3 + 0.4 * v[16]);
    offerShifted(&sel, b, Shift(abs(out_dir), 0.5 + v[17]), 0.6);
    let reservoir = finalize(sel, 3.0);
    r[94] = reservoir.seed;
    r[95] = bitcast<u32>(reservoir.w);
    r[96] = bitcast<u32>(reservoir.c);
    parity_put(&r, 97u, reservoir.f);
    r[100] = bitcast<u32>(reservoir.jac);
    r[101] = bitcast<u32>(sel.w_sum);
    parity_put(&r, 102u, sel.color);
    r[105] = sel.random_state;
    r[106] = withEnd(reservoir, 1u, 3u, albedo).path;
    parity_put(&r, 107u, ${FLEXLIGHT ? "parity_beerLambert" : "beerLambert"}(v[18] + v[19], albedo));
    ${FLEXLIGHT ? "" : "parity_put(&r, 110u, pointLightRadiance(albedo, v[18], 1.0 + v[16]));"}
    // As FlexLight's skyBSDF weighs a sample of the density against BSDF sampling, and by the power heuristic as
    // flex-cuda-pt's light sampling did
    let g_n = vec3<f32>(v[9], v[10], v[11]);
    let refracted = (dot(in_dir, g_n) <= 0.0) != (dot(out_dir, g_n) > 0.0);
    let pdf = 0.5 + v[17];
    ${FLEXLIGHT ? `parity_put(&r, 113u, skyBSDF(in_dir, out_dir, Surface(n, g_n, 0.0, material, false, 0u),
        vec2<f32>(v[18], v[19]), dot(in_dir, g_n) > 0.0, pdf, random_state));
    var power = vec3<f32>(0.0);
    for (var lobe = 0u; lobe < 3u; lobe++) {
        if ((lobe == 1u) == refracted) {
            let l = connectBSDF(in_dir, out_dir, n, material, v[18], v[19], lobe, random_state);
            power += l.throughput * (l.pdf * (1.0 / (1.0 + (l.pdf / pdf) * (l.pdf / pdf)))) / pdf;
        }
    }
    parity_put(&r, 116u, power);` : `
    parity_put(&r, 113u, neeBSDF(in_dir, out_dir, n, material, v[18], v[19], refracted, pdf, false, random_state));
    parity_put(&r, 116u, neeBSDF(in_dir, out_dir, n, material, v[18], v[19], refracted, pdf, true, random_state));`}
    // As sampleBSDF passes a ray straight through equal IORs: refraction's throughput times its probability
    ${FLEXLIGHT ? `let straight = bsdfLobes(in_dir, - in_dir, n_i, n_i, material, 1.0, 1.0);
    let through = lobeThroughput(in_dir, n_i, alpha, material, straight, 1u) * straight.p_refract;
    parity_put(&r, 119u, select(vec3<f32>(0.0), through, straight.p_refract > 0.0));` : `
    parity_put(&r, 119u, straightThrough(in_dir, n, material));`}
    // Two light tree nodes of the case, children of one, picked to a point and a normal, and a triangle's density
    let first = LightBounds(min(in_dir, out_dir), max(in_dir, out_dir) + albedo * 0.5, n, 1.0 + albedo.x,
        2.0 * albedo.y - 1.0);
    let second = LightBounds(min(n, g_n) - vec3<f32>(0.25), max(n, g_n) + vec3<f32>(albedo.z), g_n, albedo.z * v[15],
        1.0 - 2.0 * v[17]);
    let light_point = in_dir * (1.0 + 3.0 * v[16]) + g_n;
    let facing = out_dir * f32(v[17] < 1.0);
    var pick = albedo.y;
    var probability = 1.0;
    ${FLEXLIGHT ? `let shares = vec2<f32>(parity_importance(first, light_point, facing),
        parity_importance(second, light_point, facing));
    var child = 2u;
    if (!(shares.x == 0.0 && shares.y == 0.0)) {
        let total = shares.x + shares.y;
        child = u32(shares.y > 0.0 && pick * total >= shares.x);
        pick = min((pick * total - f32(child) * shares.x) / shares[child], 0.99999994);
        probability *= shares[child] / total;
    }
    r[122] = bitcast<u32>(shares.x);
    r[123] = bitcast<u32>(shares.y);
    r[124] = child;
    r[127] = bitcast<u32>(select(0.0, shares.x / (shares.x + shares.y), shares.x > 0.0));
    r[128] = bitcast<u32>(select(0.0, shares.y / (shares.x + shares.y), shares.y > 0.0));
    let toward = out_dir * (1.0 + v[15]);
    r[129] = bitcast<u32>(2.0 * (0.3 + albedo.x) * pow(length(toward), 3.0) / abs(dot(n * (1.0 + v[16]), toward)));
    let ratio = 3.0 * albedo.y / (0.5 + v[17]);
    r[130] = bitcast<u32>(select(1.0, 1.0 / (1.0 + ratio * ratio), 3.0 * albedo.y > 0.0));
    r[131] = bitcast<u32>(1.0);` : `
    r[122] = bitcast<u32>(importance(first, light_point, facing));
    r[123] = bitcast<u32>(importance(second, light_point, facing));
    r[124] = pickChild(first, second, light_point, facing, &pick, &probability);
    r[127] = bitcast<u32>(childShare(first, second, light_point, facing, 0u));
    r[128] = bitcast<u32>(childShare(first, second, light_point, facing, 1u));
    r[129] = bitcast<u32>(solidAngle(0.3 + albedo.x, n * (1.0 + v[16]), out_dir * (1.0 + v[15])));
    r[130] = bitcast<u32>(powerHeuristic(0.5 + v[17], 3.0 * albedo.y));
    r[131] = bitcast<u32>(powerHeuristic(0.5 + v[17], 0.0));`}
    // A sphere of the case seen from its incoming direction, from inside at the larger radii, as pbrt-v4 samples it
    let center = 2.0 * g_n;
    let radius = 0.5 + 2.0 * v[16];
    ${FLEXLIGHT ? `let sin2 = radius * radius / dot(center - in_dir, center - in_dir);
    var cone = 2.0;
    if (sin2 < 1.0) { cone = 1.0 - sqrt(1.0 - sin2); }
    r[132] = bitcast<u32>(1.0 / (2.0 * PI * cone));
    let cos_theta = 1.0 - albedo.x * cone;
    let sin_theta = sqrt(1.0 - cos_theta * cos_theta);
    parity_put(&r, 133u, tangentToWorld(vec3<f32>(sin_theta * cos(2.0 * PI * albedo.z), cos_theta,
        sin_theta * sin(2.0 * PI * albedo.z)), normalize(center - in_dir)));` : `
    r[132] = bitcast<u32>(sphereDensity(center, radius, in_dir));
    parity_put(&r, 133u, sampleSphere(center, radius, in_dir, albedo.x, albedo.z));`}
    r[125] = bitcast<u32>(pick);
    r[126] = bitcast<u32>(probability);
    // ReSTIR's decisions on values of the case, either side of each of their thresholds${FLEXLIGHT ? ", as FlexLight's walk, its passes and facingRay write them" : ""}
    let d_here = 0.5 + v[16];
    let d_start = 1.0 + v[17];
    let throughput = albedo * (1.0 + 2.0 * v[16]);
    let density = 0.25 + v[17];
    ${FLEXLIGHT ? `r[136] = bitcast<u32>(select(-1.0f, 1.0f, v[17] > 0.0f || dot(g_n, in_dir) < 0.0f));
    let geometry_density = abs(dot(g_n, out_dir)) / (d_here * d_here);
    let threshold = RESTIR_FOOTPRINT / (abs(dot(n, in_dir)) / (d_start * d_start));
    r[139] = u32(v[17] < 1.0 && v[15] < 1.0 && 400.0 * albedo.x * geometry_density * threshold <= 1.0f);
    r[140] = u32(400.0 * albedo.y > 0.0f && (v[17] == 0.0 || 400.0 * albedo.y * abs(dot(g_n, in_dir)) / (d_here * d_here) * threshold <= 1.0f));
    r[141] = u32(albedo.z - 0.2 > 0.0f && (v[15] == 0.0 || v[16] >= RESTIR_ROUGHNESS));
    let importancy_factor: vec3<f32> = throughput / density;
    r[142] = bitcast<u32>(clamp(max(importancy_factor.x, max(importancy_factor.y, importancy_factor.z)), 0.0f, 1.0f));
` : `r[136] = bitcast<u32>(facingSign(v[17], g_n, in_dir));
    let geometry_density = geometryDensity(g_n, out_dir, d_here);
    let threshold = footprintThreshold(geometryDensity(n, in_dir, d_start));
    r[139] = u32(withinFootprint(v[17] < 1.0, v[15] < 1.0, 400.0 * albedo.x, geometry_density, threshold));
    r[140] = u32(withinInverseFootprint(400.0 * albedo.y, v[17] == 0.0, abs(dot(g_n, in_dir)), d_here, threshold));
    r[141] = u32(roughLobe(albedo.z - 0.2, v[15] == 0.0, v[16]));
    r[142] = bitcast<u32>(survivalProbability(throughput, density));
`}
    r[137] = bitcast<u32>(geometry_density);
    r[138] = bitcast<u32>(threshold);
    parity_results[id.x] = r;
}`;
// Unsigned columns of the outputs, the others are floats
const UNSIGNED = [0, 1, 2, 8, 27, 29, 33, 74, 75, 76, 93, 94, 105, 106, 124, 139, 140, 141];

Object.assign(globalThis, globals);
// Dawn tears the device down with the GPU object, so it stays referenced
const gpu = create([]);
const device = await (await gpu.requestAdapter()).requestDevice();
const lines = readFileSync(0, "utf8").trim().split("\n").map((line) => line.trim().split(/\s+/));
const inputs = new ArrayBuffer(lines.length * 21 * 4);
lines.forEach((line, i) => {
  new Float32Array(inputs, i * 84, 20).set(line.slice(0, 20).map(Number));
  new Uint32Array(inputs, i * 84 + 80, 1)[0] = Number(line[20]);
});
const buffer = (size, usage) => device.createBuffer({ size, usage });
const cases = buffer(inputs.byteLength, GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_DST);
const results = buffer(lines.length * OUTPUTS * 4, GPUBufferUsage.STORAGE | GPUBufferUsage.COPY_SRC);
const readback = buffer(results.size, GPUBufferUsage.MAP_READ | GPUBufferUsage.COPY_DST);
device.queue.writeBuffer(cases, 0, inputs);
let source = readFileSync(process.argv[2], "utf8");
if (FLEXLIGHT) {
  // Only the allowed changes to 5a313db: surface tint, a separate absorption color and D without cancellation or BIAS.
  source = source.replace("return vec3<f32>(lobes.refract_weight * G1_l * (1.0f - lobes.F_greyscale) / lobes.p_refract);",
    "return lobes.refract_weight * G1_l * (1.0f - lobes.F_greyscale) * material.albedo / lobes.p_refract;")
    .replace("mix(lobes.F, vec3<f32>(lobes.F_greyscale), lobes.colorless_reflection)", "lobes.F")
    .replace("n_dot_h * n_dot_h * (numerator - 1.0f) + 1.0f;\n    return numerator / max(PI * denom * denom, BIAS);",
      "(1.0f - n_dot_h) * (1.0f + n_dot_h) + numerator * n_dot_h * n_dot_h;\n" +
      "    return numerator / max(PI * denom * denom, 1.17549435e-38f);");
  source += source.match(/fn beerLambert\([^]*?\n\}/)[0]
    .replace("beerLambert", "parity_beerLambert")
    .replace("instance_index: u32", "absorption: vec3<f32>")
    .replace("instance_material[instance_index].albedo", "absorption");
}
const module = device.createShaderModule({ code: (FLEXLIGHT ? LIGHT_TREE : MATERIAL) + source + KERNEL });
const pipeline = device.createComputePipeline({ layout: "auto", compute: { module, entryPoint: "parity" } });
const bindGroup = device.createBindGroup({
  layout: pipeline.getBindGroupLayout(0),
  entries: [{ binding: 0, resource: { buffer: cases } }, { binding: 1, resource: { buffer: results } }]
});
const encoder = device.createCommandEncoder();
const pass = encoder.beginComputePass();
pass.setPipeline(pipeline);
pass.setBindGroup(0, bindGroup);
pass.dispatchWorkgroups(Math.ceil(lines.length / 64));
pass.end();
encoder.copyBufferToBuffer(results, 0, readback, 0, results.size);
device.queue.submit([encoder.finish()]);
await readback.mapAsync(GPUMapMode.READ);
const words = new Uint32Array(readback.getMappedRange());
const floats = new Float32Array(words.buffer);
lines.forEach((line, i) => {
  if (!FLEXLIGHT) {
    // Integrating the radiance over a diffuse sphere must recover its power, 4 * PI * intensity.
    const radius = Math.fround(1 + Number(line[16])), area = 4 * Math.PI * radius ** 2;
    for (let channel = 0; channel < 3; channel++) {
      const power = 4 * Math.PI * Number(line[18]) * Number(line[12 + channel]);
      const emitted = floats[i * OUTPUTS + 110 + channel] * Math.PI * area;
      if (!(Math.abs(emitted - power) <= 1e-5 * Math.max(1, power))) throw new Error(`case ${i}: point light power mismatch`);
    }
  }
  // All but the point light, checked above
  const outputs = Array.from({ length: OUTPUTS }, (_, j) => j).filter((j) => j < 110 || j >= 113)
    .map((j) => (UNSIGNED.includes(j) ? words : floats)[i * OUTPUTS + j]);
  console.log(line.slice(0, 21).concat(outputs).join(" "));
});
