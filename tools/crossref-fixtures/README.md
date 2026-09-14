# crossref-fixtures

Generates golden serialization test data from `roaring-wasm` — the official
WebAssembly port of CRoaring, the C reference implementation of Roaring
Bitmaps — and converts it into a MoonBit test file.

This is how `golden_fixtures_test.mbt` (in the project root) is produced. It
exists to prove that `moonbit-roaring`'s `serialize()`/`deserialize()` are
byte-for-byte compatible with real CRoaring output, not just internally
self-consistent.

## Usage

```bash
npm install
npm run generate
```

This runs `generate.mjs` (builds bitmaps covering empty, sparse array, dense
bitmap, run, and mixed-container scenarios, serializes each with
`roaring-wasm`, writes `fixtures.json`) followed by `to_mbt.mjs` (converts
`fixtures.json` into `../../golden_fixtures_test.mbt`).

## When to regenerate

Only needed if you add new fixture scenarios to `generate.mjs` (e.g. a new
container-size boundary) or bump the `roaring-wasm` version. The checked-in
`golden_fixtures_test.mbt` does not need regeneration for normal development.

## Why `runOptimize()` matters

CRoaring does not auto-detect consecutive runs on construction — a bitmap
built from consecutive integers stays a Bitmap container until
`runOptimize()` is called explicitly. Fixture cases that need Run container
byte layout coverage set `runOptimize: true`, or the resulting bytes would
silently be Bitmap-encoded instead.
