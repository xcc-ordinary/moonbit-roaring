import { RoaringBitmap32 } from "roaring-wasm";

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

const cases = [];

// 1. empty bitmap
cases.push({ name: "empty", values: [] });

// 2. sparse array container
cases.push({ name: "sparse_array", values: [1, 100, 1000, 50000] });

// 3. dense bitmap container: 4100 scattered even values, just over the
//    4096-element array/bitmap cost threshold (4100*2=8200 > 8192).
cases.push({ name: "dense_bitmap", values: makeEven(0, 8200) });

// 4. run container: 200 consecutive values (requires explicit runOptimize;
//    CRoaring does not auto-detect runs on construction). Small enough to
//    keep the generated MoonBit literal readable while still exercising
//    the run-container byte layout (n_runs + start/length pairs).
cases.push({ name: "run_container", values: makeRange(0, 200), runOptimize: true });

// 5. mixed: array + run + bitmap across 3 buckets (high 16 bits differ)
{
  const values = [1, 500];
  for (const v of makeRange(65536, 65736)) values.push(v);
  for (const v of makeEven(131072, 147456)) values.push(v);
  cases.push({ name: "mixed_three_buckets", values, runOptimize: true });
}

// 6. exactly 6 containers (>= NO_OFFSET_THRESHOLD=4) to exercise offset header
{
  const values = [];
  for (let bucket = 0; bucket < 6; bucket++) {
    values.push(bucket * 100000 + 1);
  }
  cases.push({ name: "six_buckets_offset_header", values });
}

const fixtures = {};
for (const c of cases) {
  const bitmap = new RoaringBitmap32(c.values);
  if (c.runOptimize) {
    bitmap.runOptimize();
  }
  const bytes = bitmap.serialize(true); // portable format
  fixtures[c.name] = {
    values: c.values,
    size: bitmap.size,
    hex: toHex(bytes),
    byteLength: bytes.length,
  };
  console.log(`${c.name}: ${c.values.length} values -> ${bytes.length} bytes`);
}

import { writeFileSync } from "fs";
writeFileSync("fixtures.json", JSON.stringify(fixtures, null, 2));
console.log("Wrote fixtures.json");
