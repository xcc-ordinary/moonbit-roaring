// Live, bidirectional, cross-process interoperability check against the
// OFFICIAL Go RoaringBitmap implementation (github.com/RoaringBitmap/roaring).
//
// Third witness for the portable format, alongside the frozen official Java
// fixtures and the two live checks in tools/crossref-fixtures (CRoaring WASM)
// and tools/official-crosscheck (official Java). Two separate OS processes
// exchange bytes generated *right now*, sharing nothing but the format:
//
//   Direction A: the Go driver builds and serializes a bitmap; a fresh
//                `moon run cmd/main` process decodes it, lists every value
//                (`values`), and verifies the byte-for-byte round trip
//                (`check`).
//   Direction B: `moon run cmd/main -- encode` builds and serializes a
//                bitmap; the Go driver deserializes the bytes, lists every
//                value for element-by-element comparison, and re-serializes
//                to confirm the bytes are identical.
//
// Usage (from anywhere):  node tools/go-crosscheck/crosscheck.mjs
// Requires Go 1.22+ (GOROOT or PATH), the MoonBit toolchain on PATH, and
// network access to a Go module proxy on first run (go.mod/go.sum pin the
// reference implementation and its checksums). Exits non-zero if any case
// fails; every failure is reported.

import { spawnSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../..");

// Pinned reference implementation; go.mod and go.sum carry the exact version
// and module checksums. Bump them together and note the change in README.md.
const LIB_VERSION = "v1.9.4";

const goBin = process.env.GOROOT
  ? path.join(process.env.GOROOT, "bin", "go")
  : "go";
const buildDir = path.join(here, "build");
const driverBin = path.join(
  buildDir,
  process.platform === "win32" ? "driver.exe" : "driver",
);

function die(message) {
  console.error(message);
  process.exit(1);
}

// Build the driver once; every case then runs as a plain native process.
mkdirSync(buildDir, { recursive: true });
const build = spawnSync(goBin, ["build", "-o", driverBin, "./driver"], {
  cwd: here,
  encoding: "utf8",
});
if (build.error) {
  die(`cannot spawn go (set GOROOT or put Go 1.22+ on PATH): ${build.error.message}`);
}
if (build.status !== 0) {
  die(`go build failed:\n${build.stderr || build.stdout}`);
}

function driver(args, input) {
  const result = spawnSync(driverBin, args, {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    input: input ?? "",
  });
  if (result.error) {
    throw new Error(`cannot spawn driver: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`driver ${args[0]} exited ${result.status}: ${(result.stderr || "").trim()}`);
  }
  return result.stdout;
}

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
    throw new Error(`moon ${args[0]} exited ${result.status}: ${result.stderr || result.stdout}`);
  }
  return result.stdout;
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
    throw new Error(`${label}: cardinality ${actual.length}, expected ${expected.length}`);
  }
  for (let i = 0; i < expected.length; i++) {
    if (actual[i] !== expected[i]) {
      throw new Error(`${label}: value #${i} is ${actual[i]}, expected ${expected[i]}`);
    }
  }
}

function parseValueListing(listing, label) {
  const lines = listing.split(/\r?\n/).filter((line) => line.length > 0);
  for (const line of lines) {
    if (!/^\d+$/.test(line)) {
      throw new Error(`${label} printed a non-value line: ${line}`);
    }
  }
  return lines.map(Number);
}

// ============ Direction A: official Go -> MoonBit ============

const decodeCases = [
  { name: "empty", values: [] },
  { name: "sparse_array", values: [1, 100, 1000, 50000] },
  // 4100 scattered values: just over the array/bitmap cost threshold.
  { name: "dense_bitmap", values: makeEven(0, 8200) },
  { name: "run_container", range: [0, 200], runOptimize: true },
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
  { name: "top_of_value_space", values: [2147483648, 4294967294, 4294967295] },
];

function checkDirectionA(c) {
  const expected = c.range
    ? makeRange(c.range[0], c.range[1])
    : sortedUnique(c.values);
  const flag = c.runOptimize ? ["--run-optimize"] : [];
  // Value lists travel over stdin, so even the 8394-value mixed case never
  // approaches an OS command-line length limit.
  const hex = (
    c.range
      ? driver(["range", ...flag, String(c.range[0]), String(c.range[1])])
      : driver(["encode", ...flag, "-"], c.values.join(" ") + "\n")
  ).trim();
  if (!/^[0-9a-f]+$/.test(hex)) {
    throw new Error(`go did not print plain hex: ${hex.slice(0, 80)}`);
  }

  // Semantic agreement: every value, in order, out of a separate process.
  assertSameValues("values", parseValueListing(moon("values", hex), "values"), expected);

  // Format agreement: strict decode plus byte-for-byte re-encode.
  const report = moon("check", hex).trim();
  const match = report.match(/^ok: (\d+) values in (\d+) bytes, byte-for-byte round trip$/);
  if (!match) {
    throw new Error(`check did not report success: ${report}`);
  }
  if (Number(match[1]) !== expected.length) {
    throw new Error(`check counted ${match[1]} values, expected ${expected.length}`);
  }
  if (Number(match[2]) !== hex.length / 2) {
    throw new Error(`check counted ${match[2]} bytes, expected ${hex.length / 2}`);
  }
  return `${expected.length} values, ${hex.length / 2} bytes`;
}

// ============ Direction B: MoonBit -> official Go ============

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
  const expected = sortedUnique(c.values);

  // Semantic agreement: the official implementation recovers exactly the set
  // MoonBit encoded, across the whole unsigned 32-bit space.
  assertSameValues("decode", parseValueListing(driver(["decode", hex]), "decode"), expected);

  // Format agreement: Go re-encodes the same bytes it was handed.
  const reencoded = driver(["reencode", hex]).trim();
  if (reencoded !== hex) {
    throw new Error(`re-encode differs: ${hex.length / 2} bytes in, ${reencoded.length / 2} out`);
  }
  return `${expected.length} values, ${hex.length / 2} bytes`;
}

// ============ runner ============

const goVersion = spawnSync(goBin, ["version"], { encoding: "utf8" });
const goBanner = ((goVersion.stdout || "").trim()) || "unknown Go";
const moonVersion = spawnSync("moon", ["version"], { cwd: repoRoot, encoding: "utf8" }).stdout.trim();
console.log(`cross-process interop: official Go roaring ${LIB_VERSION} <-> ${moonVersion}`);
console.log(`${goBanner}, node ${process.version}, ${process.platform}/${process.arch}`);
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

for (const c of decodeCases) run("A go->moonbit", c, checkDirectionA);
for (const c of encodeCases) run("B moonbit->go", c, checkDirectionB);

console.log("");
if (failures > 0) {
  console.error(`go-crosscheck: ${failures} failed, ${passes} passed`);
  process.exit(1);
}
console.log(
  `go-crosscheck: all ${passes} cases passed in both directions ` +
    `(${decodeCases.length} decode + ${encodeCases.length} encode)`,
);