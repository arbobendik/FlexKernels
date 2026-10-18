// Compares outputs in the golden format against the goldens: integer columns exactly, the others within
// ABSOLUTE + (RELATIVE + ULPS * EPSILON / alpha^2) * |golden|, as the GGX denominator n_dot_h^2 (alpha^2 - 1) + 1 cancels
// down to alpha^2 near the peak of a lobe, and NaN where the golden is, as the delta lobes' masking 0 / 0 off them and
// the normalized refraction under total internal reflection, from the first column on, all by default. Given one, the
// outputs are another target's, whose random numbers differ: the columns drawing them are left out.
// Usage: node compare.mjs golden.txt outputs.txt [first]
import { readFileSync } from "node:fs";

const ABSOLUTE = 1e-5;
const RELATIVE = 1e-3;
const ULPS = 8;
const EPSILON = 2 ** -23;
// random_state of the inputs and hash, stream and the random states of pcg, sampleHalfVector, normal_distribution,
// random_sphere and random_hemisphere, of sampleBSDF its random state, refraction and lobe, neeDecision and of the
// resampled reservoir its seed, random state and path
const INTEGER_COLUMNS = [20, 21, 22, 23, 29, 48, 50, 54, 96, 97, 98, 115, 116, 127, 128];
// sampleBSDF, connectBSDF of the diffuse lobe, which replays the visible normal of its lobe choice, BSDF and what the
// resampling chooses
const RANDOM_COLUMNS = [...Array(14).keys()].map((i) => 90 + i).concat([112, 113, 114, 116, 117, 119, 120, 121, 122, 127]);
const ROUGHNESS_COLUMN = 16;
const FIRST = Number(process.argv[4] ?? 0);

// printf's inf and nan as Number reads them
const number = (word) => Number(word.replace(/inf$/, "Infinity").replace(/^-?nan$/, "NaN"));
const lines = (path) => readFileSync(path, "utf8").trim().split("\n").map((line) => line.trim().split(/\s+/).map(number));
const golden = lines(process.argv[2]);
const outputs = lines(process.argv[3]);
let failures = golden.length === outputs.length ? 0 : 1;
let worst = 0;
golden.forEach((expected, i) => expected.forEach((g, column) => {
  if (column < FIRST || (FIRST && RANDOM_COLUMNS.includes(column))) return;
  const o = outputs[i][column];
  const alpha = expected[ROUGHNESS_COLUMN] ** 2;
  const tolerance = ABSOLUTE + (RELATIVE + (alpha > 0 ? ULPS * EPSILON / alpha ** 2 : 0)) * Math.abs(g);
  const error = Math.abs(o - g) / tolerance;
  const pass = INTEGER_COLUMNS.includes(column) ? o === g : error <= 1 || Object.is(o, g);
  if (!pass && failures++ < 10) console.error(`case ${i} column ${column}: ${o} instead of ${g}`);
  if (!INTEGER_COLUMNS.includes(column) && column > 20 && !Number.isNaN(g)) worst = Math.max(worst, error);
}));
console.log(`${outputs.length} of ${golden.length} cases, ${failures} mismatches, worst error ${worst.toFixed(3)} of the tolerance`);
process.exit(failures ? 1 : 0);
