// Live, bidirectional, cross-process interoperability check.
//
// The golden fixtures prove compatibility with bytes generated in the past
// and checked into the repo. This script proves it against bytes generated
// *right now*, by two separate OS processes that share nothing but the
// Roaring portable format:
//
//   Direction A: roaring-wasm (CRoaring compiled to WASM) builds and
//                serializes a bitmap; a fresh `moon run cmd/main` process
//                decodes it and lists every value (`values`), then verifies
//                the byte-for-byte round trip (`check`).
//   Direction B: `moon run cmd/main -- encode` builds and serializes a
//                bitmap; roaring-wasm deserializes the bytes and compares
//                the recovered set element by element, then re-serializes
//                and compares the bytes.
//
// Usage (from this directory):  npm run crosscheck
// Requires the MoonBit toolchain on PATH and `npm install` done here.
// Exits non-zero if any case fails; every failure is reported, not just the
// first, so one run gives the full picture.

import { RoaringBitmap32 } from "roaring-wasm";
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../..");

// No shell: a hex argument can exceed cmd.exe's 8191-character limit, and
// CreateProcess/execvp handle long arguments fine without one.
function moon(...args) {
  const result = spawnSync("moon", ["run", "cmd/main", "--", ...args], {
    cwd: repoRoot,
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (result.error) {
    throw new Error(`cannot spawn moon: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(
      `moon ${args[0]} exited with ${result.status}: ${result.stderr || result.stdout}`,
    );
  }
  return result.stdout;
}

function toHex(bytes) {
  return Buffer.from(bytes).toString("hex");
}

function makeRange(start, end) {
  const arr = [];
  for (let i = start; i < end; i++) arr.push(i);
  return arr;
}

function makeEven(start, end) {
  const arr = [];
  for (let i = start; i < end; i += 2) arr.push(i);
  return arr;
}

function sortedUnique(values) {
  return [...new Set(values)].sort((a, b) => a - b);
}

function assertSameValues(label, actual, expected) {
  if (actual.length !== expected.length) {
    throw new Error(
      `${label}: cardinality ${actual.length}, expected ${expected.length}`,
    );
  }
  for (let i = 0; i < expected.length; i++) {
    if (actual[i] !== expected[i]) {
      throw new Error(
        `${label}: value #${i} is ${actual[i]}, expected ${expected[i]}`,
      );
    }
  }
}

// ============ Direction A: CRoaring -> MoonBit ============

const decodeCases = [
  { name: "empty", values: [] },
  { name: "sparse_array", values: [1, 100, 1000, 50000] },
  // 4100 scattered values: just over the array/bitmap cost threshold.
  { name: "dense_bitmap", values: makeEven(0, 8200) },
  { name: "run_container", values: makeRange(0, 200), runOptimize: true },
  {
    name: "mixed_three_buckets",
    values: [1, 500, ...makeRange(65536, 65736), ...makeEven(131072, 147456)],
    runOptimize: true,
  },
  // >= 4 containers, so the offset header is present.
  {
    name: "six_buckets_offset_header",
    values: [0, 1, 2, 3, 4, 5].map((bucket) => bucket * 100000 + 1),
  },
  { name: "tie_two_consecutive", values: [10, 11], runOptimize: true },
  { name: "tie_three_consecutive", values: [10, 11, 12], runOptimize: true },
  { name: "tie_four_consecutive", values: [10, 11, 12, 13], runOptimize: true },
  {
    name: "tie_scattered_with_pair",
    values: [1, 5, 9, 20, 21, 40, 77, 300, 900],
    runOptimize: true,
  },
  {
    name: "top_of_value_space",
    values: [2147483648, 4294967294, 4294967295],
  },
];

function checkDirectionA(c) {
  const bitmap = new RoaringBitmap32(c.values);
  if (c.runOptimize) bitmap.runOptimize();
  const bytes = bitmap.serialize("portable");
  const hex = toHex(bytes);
  const expected = sortedUnique(c.values);

  // Semantic agreement: every value, in order, out of a separate process.
  const listing = moon("values", hex);
  const lines = listing.split(/\r?\n/).filter((line) => line.length > 0);
  for (const line of lines) {
    if (!/^\d+$/.test(line)) {
      throw new Error(`values printed a non-value line: ${line}`);
    }
  }
  assertSameValues("values", lines.map(Number), expected);

  // Format agreement: strict decode plus byte-for-byte re-encode.
  const report = moon("check", hex).trim();
  const match = report.match(
    /^ok: (\d+) values in (\d+) bytes, byte-for-byte round trip$/,
  );
  if (!match) {
    throw new Error(`check did not report success: ${report}`);
  }
  if (Number(match[1]) !== expected.length) {
    throw new Error(
      `check counted ${match[1]} values, expected ${expected.length}`,
    );
  }
  if (Number(match[2]) !== bytes.length) {
    throw new Error(
      `check counted ${match[2]} bytes, expected ${bytes.length}`,
    );
  }
  return `${expected.length} values, ${bytes.length} bytes`;
}

// ============ Direction B: MoonBit -> CRoaring ============

const encodeCases = [
  { name: "empty_list", args: [], values: [] },
  {
    name: "sparse_list",
    args: ["1", "100", "1000", "50000"],
    values: [1, 100, 1000, 50000],
  },
  {
    name: "unordered_with_duplicates",
    args: ["1000", "1", "100", "1"],
    values: [1, 100, 1000],
  },
  { name: "max_value", args: ["4294967295"], values: [4294967295] },
  {
    name: "small_range",
    args: ["--start", "0", "--end", "10000"],
    values: makeRange(0, 10000),
  },
  {
    name: "cross_bucket_range",
    args: ["--start", "65530", "--end", "131080"],
    values: makeRange(65530, 131080),
  },
  {
    name: "large_range",
    args: ["--start", "0", "--end", "200000"],
    values: makeRange(0, 200000),
  },
  {
    name: "top_end_range",
    args: ["--start", "4294967290", "--end", "4294967295"],
    values: makeRange(4294967290, 4294967295),
  },
];

function checkDirectionB(c) {
  const hex = moon("encode", ...c.args).trim();
  if (!/^[0-9a-f]+$/.test(hex)) {
    throw new Error(`encode did not print plain hex: ${hex.slice(0, 80)}`);
  }
  const bytes = Buffer.from(hex, "hex");
  const bitmap = RoaringBitmap32.deserialize(bytes, "portable");
  const expected = sortedUnique(c.values);

  // Semantic agreement: CRoaring recovers exactly the set MoonBit encoded.
  if (bitmap.size !== expected.length) {
    throw new Error(
      `deserialize size ${bitmap.size}, expected ${expected.length}`,
    );
  }
  assertSameValues("deserialize", bitmap.toArray(), expected);

  // Format agreement: CRoaring re-encodes the same bytes it was handed.
  const reencoded = toHex(bitmap.serialize("portable"));
  if (reencoded !== hex) {
    throw new Error(
      `re-encode differs: ${bytes.length} bytes in, ${reencoded.length / 2} out`,
    );
  }
  return `${expected.length} values, ${bytes.length} bytes`;
}

// ============ runner ============

const wasmPackage = JSON.parse(
  readFileSync(path.join(here, "node_modules", "roaring-wasm", "package.json")),
);
const moonVersion = spawnSync("moon", ["version"], {
  cwd: repoRoot,
  encoding: "utf8",
}).stdout.trim();
console.log(`cross-process interop: roaring-wasm ${wasmPackage.version} <-> ${moonVersion}`);
console.log(`node ${process.version}, ${process.platform}/${process.arch}`);
console.log("");

let failures = 0;
let passes = 0;

function run(label, c, check) {
  try {
    const detail = check(c);
    passes++;
    console.log(`PASS ${label} ${c.name} (${detail})`);
  } catch (error) {
    failures++;
    console.error(`FAIL ${label} ${c.name}: ${error.message}`);
  }
}

for (const c of decodeCases) run("A croaring->moonbit", c, checkDirectionA);
for (const c of encodeCases) run("B moonbit->croaring", c, checkDirectionB);

console.log("");
if (failures > 0) {
  console.error(`crosscheck: ${failures} failed, ${passes} passed`);
  process.exit(1);
}
console.log(
  `crosscheck: all ${passes} cases passed in both directions ` +
    `(${decodeCases.length} decode + ${encodeCases.length} encode)`,
);