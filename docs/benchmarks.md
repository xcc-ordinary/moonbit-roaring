# Reproducible benchmarks

These numbers are a project baseline, not a claim that this package is faster
than another MoonBit implementation.

## Environment

- Recorded: 2026-09-18
- Toolchain: `moon 0.1.20260904`, `moonc 0.10.12`
- Host: Windows 11 10.0.26200, Intel Core i7-13650HX
- Mode and target: `--release --target wasm`
- Command: `moon bench --release --target wasm`

The fixtures cover sparse inserts, dense inserts, a long consecutive range,
mixed-container membership and set operations, and portable serialization.
Their construction is checked in as `roaring_bench_test.mbt`.

| Operation | Fixture | Mean |
| --- | --- | ---: |
| Construct | 4,096 sparse values | 73.41 ms |
| Construct | 16,384 dense values | 275.01 ms |
| Construct | 60,000-value consecutive range | 159.94 us |
| Contains | mixed containers | 247.45 ns |
| Union | mixed containers | 422.27 us |
| Intersection | mixed containers | 330.64 us |
| Serialize | mixed containers | 5.44 us |
| Deserialize | mixed containers | 8.32 us |

Results vary with hardware and toolchain version. Re-run the command above
instead of treating these numbers as a portable performance guarantee.
