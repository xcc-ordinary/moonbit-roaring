// Reproducible workload benchmarks. Run with:
//   moon bench --release --target wasm
//   moon bench --release --target wasm-gc
//   moon bench --release --target js
//
// These measure this implementation honestly; they do not claim a
// cross-language or competitor speedup.

///|
fn sparse_fixture() -> Array[UInt] {
  Array::makei(4096, i => (i * 65537).reinterpret_as_uint())
}

///|
fn dense_fixture() -> Array[UInt] {
  Array::makei(16384, i => (i * 2).reinterpret_as_uint())
}

///|
fn mixed_fixture(offset : UInt) -> RoaringBitmap {
  let values : Array[UInt] = [offset + 1U, offset + 100U]
  for i = 0; i < 6000; i = i + 1 {
    values.push(offset + 65536U + i.reinterpret_as_uint())
  }
  for i = 0; i < 16384; i = i + 2 {
    values.push(offset + 131072U + i.reinterpret_as_uint())
  }
  RoaringBitmap::from_array(values)
}

///|
test "bench construct sparse 4096 values" (it : @bench.T) {
  let values = sparse_fixture()
  it.bench(fn() {
    let bitmap = RoaringBitmap::from_array(values)
    it.keep(bitmap)
  })
}

///|
test "bench construct dense 16384 values" (it : @bench.T) {
  let values = dense_fixture()
  it.bench(fn() {
    let bitmap = RoaringBitmap::from_array(values)
    it.keep(bitmap)
  })
}

///|
test "bench construct consecutive range 60000 values" (it : @bench.T) {
  it.bench(fn() {
    let bitmap = RoaringBitmap::from_range(0U, 60000U)
    it.keep(bitmap)
  })
}

///|
test "bench contains over mixed containers" (it : @bench.T) {
  let bitmap = mixed_fixture(0U)
  it.bench(fn() {
    let mut hits = 0
    for value in [1U, 500U, 65536U, 70000U, 131072U, 147455U, 999999U] {
      if bitmap.contains(value) {
        hits = hits + 1
      }
    }
    it.keep(hits)
  })
}

///|
test "bench union mixed containers" (it : @bench.T) {
  let left = mixed_fixture(0U)
  let right = mixed_fixture(2000U)
  it.bench(fn() {
    let result = left.union(right)
    it.keep(result)
  })
}

///|
test "bench intersect mixed containers" (it : @bench.T) {
  let left = mixed_fixture(0U)
  let right = mixed_fixture(2000U)
  it.bench(fn() {
    let result = left.intersect(right)
    it.keep(result)
  })
}

///|
test "bench serialize mixed containers" (it : @bench.T) {
  let bitmap = mixed_fixture(0U)
  it.bench(fn() {
    let bytes = bitmap.serialize()
    it.keep(bytes)
  })
}

///|
test "bench deserialize mixed containers" (it : @bench.T) {
  let bytes = mixed_fixture(0U).serialize()
  it.bench(fn() {
    let result = RoaringBitmap::deserialize(bytes)
    it.keep(result)
  })
}
