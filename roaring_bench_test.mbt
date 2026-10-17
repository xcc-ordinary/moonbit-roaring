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
fn mixed_fixture(offset : UInt) -> @moonbit-roaring.RoaringBitmap {
  let values : Array[UInt] = [offset + 1U, offset + 100U]
  for i = 0; i < 6000; i = i + 1 {
    values.push(offset + 65536U + i.reinterpret_as_uint())
  }
  for i = 0; i < 16384; i = i + 2 {
    values.push(offset + 131072U + i.reinterpret_as_uint())
  }
  @moonbit-roaring.RoaringBitmap::from_array(values)
}

///|
/// Ascending values, so they all land in one bucket: this is the shape that
/// used to pay a full array copy per inserted value.
fn ascending_fixture(count : Int) -> Array[UInt] {
  Array::makei(count, i => i.reinterpret_as_uint())
}

///|
/// One value per bucket, so the fixture forces `count` distinct containers:
/// this is the shape that used to rebuild the container list per new bucket.
fn distinct_key_fixture(count : Int) -> Array[UInt] {
  Array::makei(count, i => (i * 65536).reinterpret_as_uint())
}

///|
test "bench construct sparse 4096 values" (it : @bench.T) {
  let values = sparse_fixture()
  it.bench(fn() {
    let bitmap = @moonbit-roaring.RoaringBitmap::from_array(values)
    it.keep(bitmap)
  })
}

///|
test "bench construct dense 16384 values" (it : @bench.T) {
  let values = dense_fixture()
  it.bench(fn() {
    let bitmap = @moonbit-roaring.RoaringBitmap::from_array(values)
    it.keep(bitmap)
  })
}

///|
test "bench construct consecutive range 60000 values" (it : @bench.T) {
  it.bench(fn() {
    let bitmap = @moonbit-roaring.RoaringBitmap::from_range(0U, 60000U)
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
    let result = @moonbit-roaring.RoaringBitmap::deserialize(bytes)
    it.keep(result)
  })
}

///|
// The two fixtures below exist to keep `add_many` honest. It used to be
// quadratic — one linear scan over the seen keys per value, plus one
// full-array copy per inserted value — which made 20,000 values take seconds.
// Growth is now close to linear, so doubling the input roughly doubles the
// time; if either of these starts quadrupling, the sort or the grouping has
// regressed.

///|
test "bench add_many 20000 ascending (one bucket)" (it : @bench.T) {
  let values = ascending_fixture(20000)
  it.bench(fn() {
    let bitmap = @moonbit-roaring.RoaringBitmap::from_array(values)
    it.keep(bitmap)
  })
}

///|
test "bench add_many 8000 distinct keys (many buckets)" (it : @bench.T) {
  let values = distinct_key_fixture(8000)
  it.bench(fn() {
    let bitmap = @moonbit-roaring.RoaringBitmap::from_array(values)
    it.keep(bitmap)
  })
}
