// Evaluates the generated WGSL, concatenated in front of a kernel as FlexLight does, on the inputs of each golden line
// through Dawn and prints them with its outputs in the golden format. Usage: node wgsl.mjs bsdf.wgsl < golden.txt
import { readFileSync } from "node:fs";
import { create, globals } from "webgpu";

const OUTPUTS = 25;
const KERNEL = /* wgsl */ `
struct Case { v: array<f32, 20>, random_state: u32 }
@group(0) @binding(0) var<storage, read> cases: array<Case>;
@group(0) @binding(1) var<storage, read_write> results: array<array<u32, ${OUTPUTS}>>;

fn put(r: ptr<function, array<u32, ${OUTPUTS}>>, i: u32, x: vec3<f32>) {
    (*r)[i] = bitcast<u32>(x.x);
    (*r)[i + 1u] = bitcast<u32>(x.y);
    (*r)[i + 2u] = bitcast<u32>(x.z);
}

@compute @workgroup_size(64)
fn parity(@builtin(global_invocation_id) id: vec3<u32>) {
    if (id.x >= arrayLength(&cases)) {
        return;
    }
    let v = cases[id.x].v;
    let random_state = cases[id.x].random_state;
    var s: Surface;
    s.albedo = vec3<f32>(v[12], v[13], v[14]);
    s.metallic = v[15];
    s.roughness = v[16];
    s.transparency = v[17];
    let in_dir = vec3<f32>(v[0], v[1], v[2]);
    let out_dir = vec3<f32>(v[3], v[4], v[5]);
    let n = vec3<f32>(v[6], v[7], v[8]);
    let g_n = vec3<f32>(v[9], v[10], v[11]);
    var r: array<u32, ${OUTPUTS}>;
    put(&r, 0u, BSDF(in_dir, out_dir, n, g_n, s, v[18], v[19]));
    let sample = sampleBSDF(in_dir, n, s, v[18], v[19], random_state);
    put(&r, 3u, sample.unit_direction);
    put(&r, 6u, sample.throughput);
    r[9] = sample.random_state;
    r[10] = u32(sample.refracted);
    r[11] = sample.lobe;
    r[12] = bitcast<u32>(sample.pdf);
    for (var lobe = 0u; lobe < 3u; lobe++) {
        let l = evalLobe(in_dir, out_dir, n, s, v[18], v[19], lobe, random_state);
        put(&r, 13u + 4u * lobe, l.f_cos);
        r[16u + 4u * lobe] = bitcast<u32>(l.pdf);
    }
    results[id.x] = r;
}`;
// Unsigned columns of the outputs, the others are floats
const UNSIGNED = [9, 10, 11];

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
const module = device.createShaderModule({ code: readFileSync(process.argv[2], "utf8") + KERNEL });
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
process.exit(0);
