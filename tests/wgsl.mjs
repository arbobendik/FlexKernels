// Evaluates the shared functions of a WGSL source, the generated one or, with --flexlight, FlexLight's unmodified
// pathtracer-compute.wgsl for its goldens, on the inputs of each golden line through Dawn, the kernel appended as
// FlexLight prepends the shared code, and prints them with its outputs in the golden format. The generated code takes
// FlexLight's Material, which FlexLight's shader declares. Usage: node wgsl.mjs shader.wgsl [--flexlight] < golden.txt
import { readFileSync } from "node:fs";
import { create, globals } from "webgpu";

const FLEXLIGHT = process.argv.includes("--flexlight");
const OUTPUTS = 108;
// As pathtracer-compute.wgsl declares it
const MATERIAL = /* wgsl */ `
struct Material {
    albedo: vec3<f32>,
    emissive: vec3<f32>,
    roughness: f32,
    metallic: f32,
    transmission: f32,
    ior: f32
};
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
    let material = Material(albedo, vec3<f32>(0.0), v[16], v[15], v[17], max(v[18], v[19]));
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
    r[53] = bitcast<u32>(lobes.colorless_reflection);
    r[54] = bitcast<u32>(lobes.p_diffuse);
    r[55] = bitcast<u32>(lobes.p_reflect);
    r[56] = bitcast<u32>(lobes.p_refract);
    // Each lobe sampleBSDF can choose, toward its side
    var p_lobe = array<f32, 3>(lobes.p_diffuse, lobes.p_refract, lobes.p_reflect);
    for (var lobe = 0u; lobe < 3u; lobe++) {
        let side = select(dot(n_i, out_dir) > 0.0, dot(n_i, out_dir) < 0.0, lobe == 1u);
        var throughput = vec3<f32>(0.0);
        if (p_lobe[lobe] > 1e-6 && side) {
            throughput = lobeThroughput(out_dir, n_i, alpha, material, lobes, lobe);
        }
        parity_put(&r, 57u + 4u * lobe, throughput);
        r[60u + 4u * lobe] = bitcast<u32>(lobeDensity(dot(n_i, out_dir), dot(out_dir, ggx_n), abs(dot(n, in_dir)), alpha,
            lobes, v[18], v[19], lobe));
    }
    let sample = sampleBSDF(in_dir, n, material, v[18], v[19], random_state, vec2<f32>(0.0));
    parity_put(&r, 69u, sample.unit_direction);
    parity_put(&r, 72u, sample.throughput);
    r[75] = sample.random_state;
    r[76] = u32(sample.refracted);
    r[77] = sample.lobe;
    r[78] = bitcast<u32>(sample.pdf);
    // As BSDF weighs them, the throughput of a direction of density about zero is any
    for (var lobe = 0u; lobe < 3u; lobe++) {
        let connected = connectBSDF(in_dir, out_dir, n, material, v[18], v[19], lobe, random_state);
        parity_put(&r, 79u + 4u * lobe, connected.throughput * connected.pdf);
        r[82u + 4u * lobe] = bitcast<u32>(connected.pdf);
    }
    parity_put(&r, 91u, BSDF(in_dir, out_dir, n, vec3<f32>(v[9], v[10], v[11]), material, v[18], v[19], random_state));
    r[94] = u32(neeDecision(material, dot(n, - in_dir), v[18], v[19]));
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
    r[95] = reservoir.seed;
    r[96] = bitcast<u32>(reservoir.w);
    r[97] = bitcast<u32>(reservoir.c);
    parity_put(&r, 98u, reservoir.f);
    r[101] = bitcast<u32>(reservoir.jac);
    r[102] = bitcast<u32>(sel.w_sum);
    parity_put(&r, 103u, sel.color);
    r[106] = sel.random_state;
    r[107] = withEnd(reservoir, 1u, 3u, albedo).path;
    parity_results[id.x] = r;
}`;
// Unsigned columns of the outputs, the others are floats
const UNSIGNED = [0, 1, 2, 8, 27, 29, 33, 75, 76, 77, 94, 95, 106, 107];

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
const module = device.createShaderModule({ code: (FLEXLIGHT ? "" : MATERIAL) + readFileSync(process.argv[2], "utf8") + KERNEL });
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
  const outputs = Array.from({ length: OUTPUTS }, (_, j) => (UNSIGNED.includes(j) ? words : floats)[i * OUTPUTS + j]);
  console.log(line.slice(0, 21).concat(outputs).join(" "));
});
