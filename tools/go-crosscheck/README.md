# go-crosscheck

Live, bidirectional, cross-process interoperability check against the
**official Go RoaringBitmap implementation** —
[`github.com/RoaringBitmap/roaring`](https://github.com/RoaringBitmap/roaring).

This is the third witness for the portable format, alongside:

- the frozen official Java fixtures (`tools/official-fixtures`),
- the live CRoaring-WASM exchange (`tools/crossref-fixtures`),
- the live official-Java exchange (`tools/official-crosscheck`).

## What is verified

Two separate OS processes share nothing but the Roaring portable format:

- **Direction A (Go → MoonBit)**: `driver/main.go` builds and serializes each
  case with the official library's `WriteTo` (its RoaringFormatSpec-compatible
  portable codec); a fresh `moon run cmd/main` process decodes the hex, prints
  every value with the `values` subcommand (compared element by element against
  the original set), and verifies the byte-for-byte round trip with `check`.
- **Direction B (MoonBit → Go)**: `moon run cmd/main -- encode` builds and
  serializes each case; the Go driver deserializes with `FromBuffer`, lists
  every value for element-by-element comparison, and re-serializes to confirm
  the bytes are identical.

19 cases (11 decode + 8 encode) cover empty, sparse, dense, run and
mixed-container bitmaps, the offset header, the four container-selection
tie-breaks, and values at the top of the unsigned 32-bit space. Value lists
travel over stdin, so no case approaches an OS command-line length limit. The
driver speaks the same hex protocol as the Java driver, so the same matrix
runs against both.

## Requirements

- Go 1.22+ (`GOROOT`, or `go` on PATH)
- MoonBit toolchain on PATH
- Node 18+ (no npm dependencies)
- Network access to a Go module proxy on first run; in mainland China set
  `GOPROXY=https://goproxy.cn,direct`

## Pinned reference implementation

| Module | Version |
| --- | --- |
| `github.com/RoaringBitmap/roaring` | v1.9.4 |

Apache-2.0, the same licence as this project. `go.mod` pins the version and
`go.sum` carries the module checksums verified against the Go checksum
database, so the reference code is reproducible without checking in any
third-party source. The compiled driver lands in `build/` (gitignored). To
bump the version, update `go.mod` via `go get github.com/RoaringBitmap/roaring@<version>`,
run `go mod tidy`, update `LIB_VERSION` in `crosscheck.mjs`, and note the
change here.

## Usage

```bash
node tools/go-crosscheck/crosscheck.mjs   # from the repo root
```

The script builds the driver once, prints the library version and the Go and
MoonBit toolchains it ran against, reports every failure (not just the first),
and exits non-zero on any mismatch. CI runs it on every push in the
`go-crosscheck` job.