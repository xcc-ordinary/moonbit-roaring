# moonbit-roaring

A RoaringBitmap implementation for MoonBit with true run-length optimization and official portable serialization format.

**Status**: Core, serialization, range operations, lazy iteration, and rank/select are implemented and tested (120 tests passing). Built for the MoonBit Hackathon Sept 2026.  
**License**: Apache-2.0  
**Target**: `wasm`, `wasm-gc`, `js` (verified); `native` unverified — the MoonBit runtime's own C sources fail to compile on Windows (`rand_s` implicit declaration in `runtime/env.c`), so this target has not been exercised here

---

## What This Project Does

This is a RoaringBitmap library that fills two critical gaps in the MoonBit ecosystem:

1. **真正接入主流程的 Run-length 容器优化** — 不是死代码,而是在 `add()`, `union()` 等核心操作中真正触发的自动压缩
2. **与 CRoaring 兼容的官方可移植序列化格式** — 可以与 Java/C++/Go/Rust/Python 的 RoaringBitmap 实现互通数据

### Why This Matters

RoaringBitmap is widely used in production systems (Lucene, ClickHouse, Spark, Druid) because:
- It compresses sparse integer sets **up to 90% smaller** than naive bitmaps
- It supports **fast set operations** (union, intersection) directly on compressed data
- It has a **portable binary format** that works across languages

As of 2026-09-14, the existing MoonBit implementation (`kesmeey/RoaringBitmap`, last pushed 2025-06-25) has the data structures but:
- Run-length container optimization is **never triggered** — verified by grepping its source: `optimize_container` has zero call sites, and `container_add`/`container_union` only ever promote Array → Bitmap, never detect and collapse a consecutive run
- **No serialization format** — no `serialize`/`deserialize`/`to_bytes`/`from_bytes` anywhere in its source, so it cannot exchange data with other languages

This project delivers an interoperable RoaringBitmap for MoonBit that closes both gaps, verified against real CRoaring output rather than only against itself.

---

## Installation

```bash
moon add xcc-ordinary/moonbit-roaring
```

---

## Core Features

### Phase 1: Three-Container Core
- [x] ArrayContainer (sparse data, sorted `UInt16` array)
- [x] BitmapContainer (dense data, 8KB bitmap)
- [x] RunContainer (consecutive ranges, RLE encoding)
- [x] **Auto-optimization hooks** in `add()`, `add_many()`, `remove()`, `union()`, `intersect()`, `difference()`, `xor()` — every mutation re-picks the cheapest of the three representations by byte cost
- [x] Container conversion at the **4096-element threshold** (Array ↔ Bitmap tie-break) and at the run-vs-array cost crossover
- [x] Range operations: `add_range`/`remove_range`/`contains_range`/`from_range` — a bucket fully covered by the range collapses to a single Run container in O(1), without decoding or looping over elements

### Phase 2: Official Serialization Format
- [x] `serialize(portable: Bool) -> Bytes` — output CRoaring-compatible binary
- [x] `deserialize(data: Bytes, portable: Bool) -> Result[RoaringBitmap, RoaringError]`
- [x] Round-trip tests: MoonBit → serialize → deserialize → MoonBit
- [x] **Cross-language diff tests**: verify byte-level compatibility with `roaring-wasm` (CRoaring WASM port)

### Phase 3: Query & Iteration
- [x] `iter()` — lazy `Iter[UInt]` that decodes one bucket at a time, so `.take(n)`/`.find_first(f)` can stop early instead of paying for a full `to_array()` decode
- [x] `rank(value)` / `select(index)` — CRoaring-style "how many elements ≤ x" / "the i-th smallest element", each implemented per-container without a full decode
- [x] `union_all` / `intersect_all` — fold a list of bitmaps in one call (e.g. merging several search-term postings lists)

### Phase 4: Verification & Polish
- [x] 120 test cases covering all three container types, boundary/tie-break points, and the range/iteration APIs
- [x] Bounds-checking property test: every truncated prefix of a serialized bitmap is rejected rather than read out of bounds
- [x] Golden test suite with official CRoaring-generated fixtures
- [x] Compression ratio verification (`get_stats()`, exercised in the example below)
- [x] Example: runnable inverted-index demo (`examples/inverted_index`)
- [ ] Performance benchmarks (throughput, not just byte-size compression ratio)
- [ ] Publish to mooncakes.io

---

## API Preview

```moonbit
// Create from sparse data → ArrayContainer
let bitmap = @roaring.RoaringBitmap::from_array([1U, 100U, 1000U, 10000U])

// add_range auto-converts a whole bucket to a RunContainer in O(1) —
// no per-element loop, no intermediate array of 10000 entries.
let dense = @roaring.RoaringBitmap::from_range(0U, 10000U)
// dense now uses RunContainer internally (a few bytes, not 8KB)

// Serialize to official portable format
let bytes = dense.serialize(true)

// Deserialize from CRoaring-generated data
let restored = match @roaring.RoaringBitmap::deserialize(bytes, true) {
  Ok(bm) => bm
  Err(e) => {
    println("deserialize failed: \{e}")
    panic()
  }
}

// Fast set operations
let result = bitmap1.union(bitmap2).intersect(bitmap3)

// Merge several bitmaps at once
let merged = @roaring.RoaringBitmap::union_all([bitmap1, bitmap2, bitmap3])

// Lazy iteration and rank/select
let first_three = dense.iter().take(3).to_array()
let how_many_le_500 = dense.rank(500U)
let fifth_smallest = dense.select(4)
```

---

## Differentiators vs. Existing Implementation

As of 2026-09-14, `kesmeey/RoaringBitmap` (last pushed 2025-06-25):

| Feature | `kesmeey/RoaringBitmap` | This Project |
|---------|------------------------|--------------|
| ArrayContainer | ✅ | ✅ |
| BitmapContainer | ✅ | ✅ |
| RunContainer | ⚠️ Defined but never triggered (`optimize_container` has zero call sites) | ✅ Hooked into every mutation |
| Portable serialization | ❌ No implementation | ✅ CRoaring-compatible |
| Cross-language interop | ❌ | ✅ Tested with `roaring-wasm` |
| Compression for consecutive data | ❌ Falls back to Bitmap (8KB) | ✅ Uses Run (< 100 bytes) |
| Range operations (`add_range`, etc.) | ❌ | ✅ O(1) fast path for full-bucket ranges |
| Lazy iteration / rank / select | ❌ | ✅ `iter()`, `rank()`, `select()` |
| Test coverage | ⚠️ Basic | ✅ 120 cases + golden fixtures |

---

## Non-Goals (Out of Scope for This Hackathon)

- **ps (Roaring64)** — this project focuses on 32-bit (`UInt32`) bitmaps only
- **Thread-safe concurrent access** — MoonBit's concurrency story is still evolving; we provide immutable operations
- **Fancy optimizations** (SIMD, AVX2 vectorization) — correctness and interop first, then optimize
- **Frozen/mmap-able format** — portable format only; advanced formats are future work

---

## Verification Strategy

### How We Prove Correctness

1. **Unit tests** — 120 test cases across container types, operations, and boundary/tie-break points
2. **Bounds-checking property test** — every truncated prefix of a serialized bitmap must be rejected, proving no length check is missing in the parse path
3. **Golden tests** — use `roaring-wasm` (official CRoaring WASM port) to generate reference data:
   ```javascript
   const bitmap = new RoaringBitmap32([1, 2, 3, 100, 65536]);
   const bytes = bitmap.serialize(true); // portable format
   // Feed `bytes` to MoonBit deserializer, verify exact match
   ```
4. **Compression ratio tests** — verify Run containers actually compress consecutive ranges

### Test Data Sources

- **Official spec**: https://github.com/RoaringBitmap/RoaringFormatSpec
- **Reference impl**: CRoaring (C), roaring-rs (Rust), roaring-wasm (WASM)
- **Already verified**: regenerating the fixtures from `roaring-wasm` v1.1.0 (`cd tools/crossref-fixtures && npm install && npm run generate`) reproduces the checked-in `golden_fixtures_test.mbt` byte-identically, across all six fixture shapes (empty, sparse array, dense bitmap, run, mixed three-bucket, six-bucket offset header)

---

## Use Cases

A complete runnable version of the inverted-index case below lives in
`examples/inverted_index` — run it with `moon run examples/inverted_index`.

### 1. Search Engine Inverted Index
```moonbit
// Document IDs matching "machine" AND "learning"
let docs_machine = @roaring.RoaringBitmap::from_array([1U, 5U, 10U, 15U, 20U])
let docs_learning = @roaring.RoaringBitmap::from_array([5U, 15U, 25U, 30U])
let result = docs_machine.intersect(docs_learning) // [5, 15]

// Merge postings lists for several terms at once
let all_terms = @roaring.RoaringBitmap::union_all([docs_machine, docs_learning])
```

### 2. Time-Series Event Filtering
```moonbit
// Events in time range [1000, 5000) — the O(1) range fast path, not a loop
let events = @roaring.RoaringBitmap::from_range(1000U, 5000U)
// Internally uses RunContainer (< 100 bytes, not 8KB Bitmap)
let serialized = events.serialize(true)
// Send to Python analytics pipeline for further processing
```

### 3. Cross-Language Data Exchange
```moonbit
// MoonBit service serializes user IDs
let active_users = @roaring.RoaringBitmap::from_array([101U, 102U, 105U, 200U])
let bytes = active_users.serialize(true)

// Java/Go/Rust service deserializes the same data
// (using their respective RoaringBitmap libraries)
```

---

## Development Roadmap

| Date | Milestone | Status |
|------|-----------|--------|
| Sept 13 | Project setup, ecosystem gap analysis, API design | ✅ Done |
| Sept 14-15 | Container types + auto-optimization hooks | ✅ Done |
| Sept 16-17 | Set operations (union, intersect, difference, xor) | ✅ Done |
| Sept 18 | Run-length heuristics + conversion logic | ✅ Done |
| Sept 19-20 | Serialization format + cross-language diff tests | ✅ Done |
| Sept 21-22 | Test suite (120 cases) + golden fixtures | ✅ Done |
| — | Range ops, lazy iteration, rank/select, multi-way merge | ✅ Done |
| Sept 23 | Example + documentation | ✅ Done |
| Sept 24 | Final verification, publish to mooncakes.io | ⏳ Pending |

---

## Contributing

Contributions welcome after Sept 24! For now, this is a solo hackathon project.

---

## License

Apache-2.0 — same as the official CRoaring implementation

---

## References

- [RoaringBitmap Official Site](https://roaringbitmap.org/)
- [RoaringFormatSpec](https://github.com/RoaringBitmap/RoaringFormatSpec)
- [CRoaring (reference impl)](https://github.com/RoaringBitmap/CRoaring)
- [MoonBit Language](https://www.moonbitlang.com/)

---

**This project is built for the 2026 September MoonBit Hackathon (New Ecosystem Projects track).**
