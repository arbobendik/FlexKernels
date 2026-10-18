// Evaluates the shared functions of a WGSL source, the generated one or, with --flexlight, FlexLight's unmodified
// pathtracer-compute.wgsl for its goldens, on the inputs of each golden line through Dawn, the kernel appended as
// FlexLight prepends the shared code, and prints them with its outputs in the golden format. The generated code takes
// FlexLight's Material, which FlexLight's shader declares. Usage: node wgsl.mjs shader.wgsl [--flexlight] < golden.txt
import { readFileSync } from "node:fs";
import { create, globals } from "webgpu";

const FLEXLIGHT = process.argv.includes("--flexlight");
const OUTPUTS = 41;
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
    parity_results[id.x] = r;
}`;
// Unsigned columns of the outputs, the others are floats
const UNSIGNED = [0, 1, 2, 8, 27, 29, 33];

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
