// Live, bidirectional, cross-process interoperability check against the
// OFFICIAL Java RoaringBitmap implementation (org.roaringbitmap:RoaringBitmap).
//
// The golden fixtures already decode files the official Java implementation
// generated in the past. This script goes further: two separate OS processes
// exchange bytes generated *right now*, sharing nothing but the portable
// format:
//
//   Direction A: the Java driver builds and serializes a bitmap; a fresh
//                `moon run cmd/main` process decodes it, lists every value
//                (`values`), and verifies the byte-for-byte round trip
//                (`check`).
//   Direction B: `moon run cmd/main -- encode` builds and serializes a
//                bitmap; the Java driver deserializes the bytes, lists every
//                value for element-by-element comparison, and re-serializes
//                to confirm the bytes are identical.
//
// Usage (from anywhere):  node tools/official-crosscheck/crosscheck.mjs
// Requires a JDK 17+ (JAVA_HOME or PATH), the MoonBit toolchain on PATH, and
// the pinned library jar in lib/ — see README.md for the download command
// and checksum. Exits non-zero if any case fails; every failure is reported.

import { spawnSync } from "node:child_process";
import { existsSync, mkdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(here, "../..");

// Pinned reference-implementation provenance. Bump both together and record
// the new checksum in README.md.
const LIB_VERSION = "1.6.30";
const LIB_SHA1 = "6b25756b77a7f56da2428f9eef6ba6a56b614617";
const jarPath = path.join(here, "lib", `RoaringBitmap-${LIB_VERSION}.jar`);
const buildDir = path.join(here, "build");

const javaHome = process.env.JAVA_HOME;
const javaBin = javaHome ? path.join(javaHome, "bin", "java") : "java";
const javacBin = javaHome ? path.join(javaHome, "bin", "javac") : "javac";

function die(message) {
  console.error(message);
  process.exit(1);
}

if (!existsSync(jarPath)) {
  die(
    `missing ${jarPath}\n` +
      `Download the pinned jar and verify its SHA-1 first; see README.md.`,
  );
}

// Compile the driver once; every case then runs as a plain `java` process.
mkdirSync(buildDir, { recursive: true });
const compile = spawnSync(
  javacBin,
  ["-encoding", "UTF-8", "-cp", jarPath, "-d", buildDir, path.join(here, "ReferenceDriver.java")],
  { encoding: "utf8" },
);
if (compile.error) {
  die(`cannot spawn javac (set JAVA_HOME or put a JDK 17+ on PATH): ${compile.error.message}`);
}
if (compile.status !== 0) {
  die(`javac failed:\n${compile.stderr}`);
}
const classpath = jarPath + path.delimiter + buildDir;

function java(args, input) {
  const result = spawnSync(javaBin, ["-cp", classpath, "ReferenceDriver", ...args], {
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
    input: input ?? "",
  });
  if (result.error) {
    throw new Error(`cannot spawn java: ${result.error.message}`);
  }
  if (result.status !== 0) {
    throw new Error(`java ${args[0]} exited ${result.status}: ${(result.stderr || "").trim()}`);
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

// ============ Direction A: official Java -> MoonBit ============

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
      ? java(["range", ...flag, String(c.range[0]), String(c.range[1])])
      : java(["encode", ...flag, "-"], c.values.join(" ") + "\n")
  ).trim();
  if (!/^[0-9a-f]+$/.test(hex)) {
    throw new Error(`java did not print plain hex: ${hex.slice(0, 80)}`);
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

// ============ Direction B: MoonBit -> official Java ============

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
  // MoonBit encoded, including values above Java's signed-int maximum.
  assertSameValues("decode", parseValueListing(java(["decode", hex]), "decode"), expected);

  // Format agreement: Java re-encodes the same bytes it was handed.
  const reencoded = java(["reencode", hex]).trim();
  if (reencoded !== hex) {
    throw new Error(`re-encode differs: ${hex.length / 2} bytes in, ${reencoded.length / 2} out`);
  }
  return `${expected.length} values, ${hex.length / 2} bytes`;
}

// ============ runner ============

const javaVersion = spawnSync(javaBin, ["-version"], { encoding: "utf8" });
const javaBanner = ((javaVersion.stderr || javaVersion.stdout || "").split(/\r?\n/)[0]) || "unknown JDK";
const moonVersion = spawnSync("moon", ["version"], { cwd: repoRoot, encoding: "utf8" }).stdout.trim();
console.log(`cross-process interop: official Java RoaringBitmap ${LIB_VERSION} <-> ${moonVersion}`);
console.log(`jar sha1: ${LIB_SHA1}`);
console.log(`${javaBanner}, node ${process.version}, ${process.platform}/${process.arch}`);
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

for (const c of decodeCases) run("A java->moonbit", c, checkDirectionA);
for (const c of encodeCases) run("B moonbit->java", c, checkDirectionB);

console.log("");
if (failures > 0) {
  console.error(`official-crosscheck: ${failures} failed, ${passes} passed`);
  process.exit(1);
}
console.log(
  `official-crosscheck: all ${passes} cases passed in both directions ` +
    `(${decodeCases.length} decode + ${encodeCases.length} encode)`,
);