# Reproducible benchmarks

These numbers are a project baseline, not a claim that this package is faster
than another MoonBit implementation.

## Environment

- Recorded: 2026-11-22
- Toolchain: `moon 0.1.20261119`, `moonc v0.10.22+124d61d05`,
  `moonrun 0.1.20261119` (`moon version --all`)
- Host: Windows 11 10.0.26300, 13th Gen Intel Core i7-13650HX
- Mode and target: `--release --target wasm`
- Command: `moon bench --release --target wasm`

The fixtures cover sparse and dense construction, batch `add_many`, a long
consecutive range, mixed-container membership and set operations, multi-way
union, a wide `flip`, `run_optimize`, seek iteration, range queries, and
portable serialization. Their construction is checked in as
`roaring_bench_test.mbt`.

| Operation | Fixture | Mean |
| --- | --- | ---: |
| Construct | 4,096 sparse values | 844.91 us |
| Construct | 16,384 dense values | 566.46 us |
| Construct | 60,000-value consecutive range | 160.17 us |
| add_many | 20,000 ascending values (one bucket) | 148.69 us |
| add_many | 8,000 distinct keys (many buckets) | 1.67 ms |
| Contains | mixed containers | 209.31 ns |
| Union | mixed containers | 67.12 us |
| Intersection | mixed containers | 55.50 us |
| union_all | 32 single-bucket bitmaps | 4.31 us |
| flip | wide range, 2,048 buckets | 261.72 us |
| run_optimize | dense Bitmap bucket (9,000 even values) | 6.84 us |
| iter_from | seek near the end of a 4,096-bucket bitmap | 108.72 us |
| range | narrow window in a 2M-value dense bitmap | 105.44 us |
| range_cardinality | full space over 6 sparse buckets | 266.48 ns |
| Serialize | mixed containers | 3.75 us |
| Deserialize | mixed containers | 3.88 us |
| Deserialize | 32 Bitmap containers (8,192 even values each) | 101.91 us |

The 2026-09-18 baseline previously recorded here reflected earlier code (before
the batch-insert, word-level set-operation, single-pass `flip`, and seek-based
range optimizations) on `moonc 0.10.12`; it is superseded by the run above. The
before/after pairs for each optimization are recorded in
`docs/competition/resubmission-strategy.zh-CN.md` and the commit history, always
as this project's own baseline rather than a cross-implementation comparison.

Results vary with hardware and toolchain version. Re-run the command above
instead of treating these numbers as a portable performance guarantee.