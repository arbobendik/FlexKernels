// Compares outputs in the golden format against the goldens: integer columns exactly, the others within
// ABSOLUTE + (RELATIVE + ULPS * EPSILON / alpha^2) * |golden|, as the GGX denominator n_dot_h^2 (alpha^2 - 1) + 1 cancels
// down to alpha^2 near the peak of a lobe. Usage: node compare.mjs golden.txt outputs.txt
import { readFileSync } from "node:fs";

const ABSOLUTE = 1e-5;
const RELATIVE = 1e-3;
const ULPS = 8;
const EPSILON = 2 ** -23;
// random_state of the inputs and random_state, refracted and lobe of sampleBSDF
const INTEGER_COLUMNS = [20, 30, 31, 32];
const ROUGHNESS_COLUMN = 16;

const lines = (path) => readFileSync(path, "utf8").trim().split("\n").map((line) => line.trim().split(/\s+/).map(Number));
const golden = lines(process.argv[2]);
const outputs = lines(process.argv[3]);
let failures = golden.length === outputs.length ? 0 : 1;
let worst = 0;
golden.forEach((expected, i) => expected.forEach((g, column) => {
  const o = outputs[i][column];
  const alpha = expected[ROUGHNESS_COLUMN] ** 2;
  const tolerance = ABSOLUTE + (RELATIVE + (alpha > 0 ? ULPS * EPSILON / alpha ** 2 : 0)) * Math.abs(g);
  const error = Math.abs(o - g) / tolerance;
  const pass = INTEGER_COLUMNS.includes(column) ? o === g : error <= 1;
  if (!pass && failures++ < 10) console.error(`case ${i} column ${column}: ${o} instead of ${g}`);
  if (!INTEGER_COLUMNS.includes(column) && column > 20) worst = Math.max(worst, error);
}));
console.log(`${outputs.length} of ${golden.length} cases, ${failures} mismatches, worst error ${worst.toFixed(3)} of the tolerance`);
process.exit(failures ? 1 : 0);
