// Each generated WGSL file through Dawn's compiler: any error but a name its consumer declares fails
import { readFileSync } from "node:fs";
import { create, globals } from "webgpu";

Object.assign(globalThis, globals);
// Kept referenced: the device is torn down with the GPU object
const gpu = create([]);
const device = await (await gpu.requestAdapter()).requestDevice();
let failed = 0;
for (const file of process.argv.slice(2)) {
  const info = await device.createShaderModule({ code: readFileSync(file, "utf8") }).getCompilationInfo();
  const errors = info.messages.filter((m) => m.type === "error" && !/unresolved/.test(m.message));
  for (const m of errors) console.log(`${file}:${m.lineNum}:${m.linePos}: ${m.message}`);
  failed += errors.length > 0;
  console.log(`${file}: ${errors.length > 0 ? "FAILED" : "parses"}`);
}
process.exit(failed > 0 ? 1 : 0);
