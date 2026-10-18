// Columns within ABSOLUTE + (RELATIVE + ULPS * EPSILON / alpha^2) * |golden|, integers exactly
// Usage: node compare.mjs golden.txt outputs.txt [first]
import { readFileSync } from "node:fs";

const ABSOLUTE = 1e-5;
const RELATIVE = 1e-3;
const ULPS = 8;
const EPSILON = 2 ** -23;
const INTEGER_COLUMNS = [20, 21, 22, 23, 29, 48, 50, 54, 96, 97, 98, 115, 116, 127, 128];
// Golden columns no output fills
const RETIRED_COLUMNS = [54, 55, 56, 57];
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
  if (RETIRED_COLUMNS.includes(column)) return;
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
