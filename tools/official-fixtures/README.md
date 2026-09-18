# Official RoaringFormatSpec fixtures

This directory vendors the two minimum conformance fixtures required by the
official [RoaringFormatSpec](https://github.com/RoaringBitmap/RoaringFormatSpec/tree/master/testdata):

- `testdata/bitmapwithoutruns.bin`
  - SHA-256: `D719AE2E0150A362EF7CF51C361527585891F01460B1A92BCFB6A7257282A442`
- `testdata/bitmapwithruns.bin`
  - SHA-256: `1F1909BFDD354FA2F0694FE88B8076833CA5383AD9FC3F68F2709C84A2AB70E3`

The files were copied without modification from commit `master` of
`RoaringBitmap/RoaringFormatSpec` on 2026-09-17. They are Apache-2.0 licensed;
see the upstream repository and this project's `LICENSE`.

Regenerate the checked-in MoonBit test after updating the binaries:

```powershell
node tools/official-fixtures/generate.mjs
moon fmt
moon test official_format_test.mbt
```

The generated test verifies both directions: MoonBit parses each Java-produced
fixture with the expected content, and serializing the parsed bitmap reproduces
the original bytes exactly.

