// Learn more about moon.mod configuration:
// https://docs.moonbitlang.com/en/latest/toolchain/moon/module.html
//
// To add a dependency, run this command in your terminal:
//   moon add moonbitlang/x
//
// Or manually declare it in `import`, for example:
// import {
//   "moonbitlang/x@0.4.6",
// }

name = "xcc-ordinary/moonbit-roaring"

version = "0.1.0"

readme = "README.md"

repository = "https://github.com/xcc-ordinary/moonbit-roaring"

license = "Apache-2.0"

keywords = [
  "roaring",
  "bitmap",
  "compression",
  "serialization",
  "data-structures",
]

preferred_target = "wasm"

description = "Production-ready RoaringBitmap with true run-length optimization and CRoaring-compatible portable serialization format"
