// Columns within ABSOLUTE + (RELATIVE + ULPS * EPSILON / alpha^2) * |golden|, integers exactly
// Usage: node compare.mjs golden.txt outputs.txt [first]
import { readFileSync } from "node:fs";

const ABSOLUTE = 1e-5;
const RELATIVE = 1e-3;
const ULPS = 8;
const EPSILON = 2 ** -23;
const INTEGER_COLUMNS = [20, 21, 22, 23, 29, 48, 50, 54, 95, 96, 97, 114, 115, 126, 127, 142];
// Golden columns no output fills
const RETIRED_COLUMNS = [54, 55, 56, 57, 167, 168, 169];
const RANDOM_COLUMNS = [...Array(14).keys()].map((i) => 89 + i).concat([111, 112, 113, 115, 116, 118, 119, 120, 121, 126]);
const NEE_COLUMNS = [...Array(6).keys()].map((i) => 131 + i);
const dot = (v, a, b) => v[a] * v[b] + v[a + 1] * v[b + 1] + v[a + 2] * v[b + 2];
const draws = (v) => (dot(v, 0, 9) <= 0) === (dot(v, 3, 9) > 0) && (1 - v[17]) * (1 - v[15]) > 0;
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
  if (column < FIRST || (FIRST && (RANDOM_COLUMNS.includes(column) || (NEE_COLUMNS.includes(column) && draws(expected)))))
    return;
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
