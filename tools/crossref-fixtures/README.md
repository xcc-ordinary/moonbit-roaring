# crossref-fixtures

Generates golden serialization test data from `roaring-wasm` — a third-party
WebAssembly port of CRoaring, the C reference implementation of Roaring
Bitmaps — and converts it into a MoonBit test file. Also runs a live
bidirectional cross-process interoperability check against the same reference
implementation.

This is how `golden_fixtures_test.mbt` (in the project root) is produced. It
exists to prove that `moonbit-roaring`'s `serialize()`/`deserialize()` are
byte-for-byte compatible with real CRoaring output, not just internally
self-consistent.

## Usage

```bash
npm install
npm run generate    # regenerate the checked-in golden fixtures
npm run crosscheck  # live cross-process check, no files written
```

`generate` runs `generate.mjs` (builds bitmaps covering empty, sparse array,
dense bitmap, run, and mixed-container scenarios, serializes each with
`roaring-wasm`, writes `fixtures.json`) followed by `to_mbt.mjs` (converts
`fixtures.json` into `../../golden_fixtures_test.mbt`).

## Live cross-process check

`crosscheck.mjs` complements the frozen fixtures with bytes generated *right
now*, exchanged between two separate OS processes that share no code:

- **Direction A (CRoaring → MoonBit)**: `roaring-wasm` builds and serializes
  each case; a fresh `moon run cmd/main` process decodes the hex, prints every
  value with the `values` subcommand (compared element by element against the
  original set), and verifies the byte-for-byte round trip with `check`.
- **Direction B (MoonBit → CRoaring)**: `moon run cmd/main -- encode` builds
  and serializes each case from value lists or `--start`/`--end` ranges;
  `roaring-wasm` deserializes the bytes, compares the recovered set element by
  element, and re-serializes to confirm the bytes are identical.

Cases cover empty, sparse, dense, run and mixed-container bitmaps, the offset
header, the four container-selection tie-breaks, and values at the top of the
32-bit space. The script prints the `roaring-wasm` and MoonBit toolchain
versions it ran against, reports every failure (not just the first), and exits
non-zero on any mismatch. It needs the MoonBit toolchain on PATH and writes no
files. CI runs it on every push.

## When to regenerate

Only needed if you add new fixture scenarios to `generate.mjs` (e.g. a new
container-size boundary) or bump the `roaring-wasm` version. The checked-in
`golden_fixtures_test.mbt` does not need regeneration for normal development.
`crosscheck` never needs regeneration — it generates its data on every run.

## Provenance and licence

`roaring-wasm` is Apache-2.0, the same licence as this project, so the
generated fixtures carry no additional obligations. `node_modules/` is
gitignored and never distributed: only `generate.mjs`, `to_mbt.mjs` and the
generated `golden_fixtures_test.mbt` are checked in, and the latter contains
byte literals rather than any upstream source.

## Why `runOptimize()` matters

CRoaring does not auto-detect consecutive runs on construction — a bitmap
built from consecutive integers stays a Bitmap container until
`runOptimize()` is called explicitly. Fixture cases that need Run container
byte layout coverage set `runOptimize: true`, or the resulting bytes would
silently be Bitmap-encoded instead.
