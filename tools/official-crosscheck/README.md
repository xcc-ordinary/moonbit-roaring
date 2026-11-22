# official-crosscheck

Live, bidirectional, cross-process interoperability check against the
**official Java RoaringBitmap implementation** — `org.roaringbitmap:RoaringBitmap`,
the library family that generated the official `RoaringFormatSpec/testdata`
files this repo's test suite already decodes.

Where `tools/crossref-fixtures` exchanges bytes with a third-party CRoaring
WASM port, this tool exchanges them with the official Java implementation
running in its own JVM process. Together they provide two independent
cross-process witnesses for the portable format, on top of the frozen
official fixtures.

## What is verified

Two separate OS processes share nothing but the Roaring portable format:

- **Direction A (Java → MoonBit)**: `ReferenceDriver.java` builds and
  serializes each case; a fresh `moon run cmd/main` process decodes the hex,
  prints every value with the `values` subcommand (compared element by element
  against the original set), and verifies the byte-for-byte round trip with
  `check`.
- **Direction B (MoonBit → Java)**: `moon run cmd/main -- encode` builds and
  serializes each case; the Java driver deserializes the bytes, lists every
  value for element-by-element comparison, and re-serializes to confirm the
  bytes are identical.

19 cases (11 decode + 8 encode) cover empty, sparse, dense, run and
mixed-container bitmaps, the offset header, the four container-selection
tie-breaks, and values at the top of the 32-bit space — including `4294967295`,
which must survive Java's signed `int` as an unsigned value. Value lists travel
over stdin, so no case approaches an OS command-line length limit.

### An observed tie-break difference, handled correctly

At exactly three consecutive values, the official Java `runOptimize()` keeps
an Array container where CRoaring picks a Run (`[10, 11, 12]` serializes to 22
bytes in Java vs 15 in CRoaring). Both encodings are format-valid. The check
compares values and byte-for-byte round trips rather than demanding one
implementation's container choice, so it passes against both — which is
exactly the interoperability property the portable format promises.

## Requirements

- JDK 17+ (`JAVA_HOME`, or `java`/`javac` on PATH)
- MoonBit toolchain on PATH
- Node 18+ (no npm dependencies)
- The pinned library jar in `lib/` (below); `lib/` and `build/` are gitignored

## Pinned reference implementation

| Artifact | Version | SHA-1 |
| --- | --- | --- |
| `org.roaringbitmap:RoaringBitmap` | 1.6.30 | `6b25756b77a7f56da2428f9eef6ba6a56b614617` |

Apache-2.0, the same licence as this project. The jar is downloaded on demand
rather than checked in. From this directory:

```bash
mkdir -p lib
curl -fsSL -o lib/RoaringBitmap-1.6.30.jar \
  https://repo1.maven.org/maven2/org/roaringbitmap/RoaringBitmap/1.6.30/RoaringBitmap-1.6.30.jar
echo "6b25756b77a7f56da2428f9eef6ba6a56b614617  lib/RoaringBitmap-1.6.30.jar" | sha1sum -c -
```

PowerShell equivalent:

```powershell
New-Item -ItemType Directory -Force lib | Out-Null
curl.exe -fsSL -o lib\RoaringBitmap-1.6.30.jar `
  https://repo1.maven.org/maven2/org/roaringbitmap/RoaringBitmap/1.6.30/RoaringBitmap-1.6.30.jar
(Get-FileHash lib\RoaringBitmap-1.6.30.jar -Algorithm SHA1).Hash.ToLower()
# must equal 6b25756b77a7f56da2428f9eef6ba6a56b614617
```

To bump the version, update `LIB_VERSION` and `LIB_SHA1` in `crosscheck.mjs`,
the commands above, and the CI download step together.

## Usage

```bash
node tools/official-crosscheck/crosscheck.mjs   # from the repo root
```

The script compiles the driver once into `build/`, prints the library version,
jar checksum, JDK and MoonBit toolchain it ran against, reports every failure
(not just the first), and exits non-zero on any mismatch. CI runs it on every
push in the `official-crosscheck` job.