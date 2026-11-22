// Reproducible workload benchmarks. Run with:
//   moon bench --release --target wasm
//   moon bench --release --target wasm-gc
//   moon bench --release --target js
//
// These measure this implementation honestly; they do not claim a
// cross-language or competitor speedup.

///|
fn sparse_fixture() -> Array[UInt32] {
  Array::makei(4096, i => (i * 65537).reinterpret_as_uint())
}

///|
fn dense_fixture() -> Array[UInt32] {
  Array::makei(16384, i => (i * 2).reinterpret_as_uint())
}

///|
fn mixed_fixture(offset : UInt32) -> @moonbit-roaring.RoaringBitmap {
  let values : Array[UInt32] = [offset + 1U, offset + 100U]
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
fn ascending_fixture(count : Int32) -> Array[UInt32] {
  Array::makei(count, i => i.reinterpret_as_uint())
}

///|
/// One value per bucket, so the fixture forces `count` distinct containers:
/// this is the shape that used to rebuild the container list per new bucket.
fn distinct_key_fixture(count : Int32) -> Array[UInt32] {
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

///|
// `flip` assembles its result in one merge walk, like add_range/remove_range.
// It used to rebuild the container list per bucket AND materialize every
// absent full bucket as a 65536-element array, which made a wide flip
// quadratic in the buckets touched. 2048 buckets should stay millisecond-
// scale; if this starts climbing quadratically, the walk has regressed.

///|
test "bench flip wide range (2048 buckets)" (it : @bench.T) {
  let empty = @moonbit-roaring.RoaringBitmap::new()
  it.bench(fn() {
    let flipped = empty.flip(0U, (2048 * 65536 - 1).reinterpret_as_uint())
    it.keep(flipped)
  })
}

///|
// run_optimize on a dense Bitmap container that stays a Bitmap: the word path
// re-picks the representation from the words alone, with no 65536-element
// decode, no array_to_runs scan and no re-encode back to words.

///|
test "bench run_optimize dense bitmap" (it : @bench.T) {
  let bm = @moonbit-roaring.RoaringBitmap::from_array(
    Array::makei(9000, i => (i * 2).reinterpret_as_uint()),
  )
  it.bench(fn() {
    let optimized = bm.run_optimize()
    it.keep(optimized)
  })
}

///|
// `iter_from` seeks with a binary search instead of walking from the start.
// The comparison that motivates it — `iter().filter(v => v >= x)` — decodes
// every bucket before x, which on this fixture is 4000 buckets and seconds of
// work; `iter_from` decodes exactly one. Only the seek is benchmarked here,
// because the filter version is too slow to run repeatedly.

///|
test "bench iter_from near the end of a wide bitmap" (it : @bench.T) {
  let bm = @moonbit-roaring.RoaringBitmap::new().add_range(
    0U,
    (4096 * 65536).reinterpret_as_uint(),
  )
  it.keep(bm)
  it.bench(fn() {
    let found = bm
      .iter_from((4000 * 65536).reinterpret_as_uint())
      .take(1)
      .to_array()
    it.keep(found)
  })
}

///|
// range_cardinality over the whole 32-bit space of a sparse bitmap: it walks
// the few present containers instead of probing all 65536 possible bucket
// keys. If this climbs toward the bucket-key count, the walk has regressed.

///|
test "bench range_cardinality wide sparse" (it : @bench.T) {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([
    100U, 70000U, 200000U, 1000000U, 100000000U, 4000000000U,
  ])
  it.keep(bm)
  it.bench(fn() {
    let count = bm.range_cardinality(0U, 0xFFFFFFFFU)
    it.keep(count)
  })
}

///|
// A narrow window inside a wide dense bitmap: only the touched bucket is
// decoded via iter_from, not the whole bitmap materialized and re-sorted.

///|
test "bench range narrow dense" (it : @bench.T) {
  let bm = @moonbit-roaring.RoaringBitmap::new().add_range(0U, 2000000U)
  it.keep(bm)
  it.bench(fn() {
    let window = bm.range(1000000U, 1000010U)
    it.keep(window)
  })
}

///|
// Many bitmaps with disjoint bucket sets: union_all merges them pairwise in
// balanced rounds, so intermediate results stay small instead of re-walking a
// growing accumulator under a left fold.

///|
test "bench union_all many buckets" (it : @bench.T) {
  let parts : Array[@moonbit-roaring.RoaringBitmap] = []
  for i = 0; i < 32; i = i + 1 {
    let base = (i * 65536).reinterpret_as_uint()
    parts.push(
      @moonbit-roaring.RoaringBitmap::new().add_range(base, base + 30000U),
    )
  }
  it.keep(parts)
  it.bench(fn() {
    let merged = @moonbit-roaring.RoaringBitmap::union_all(parts)
    it.keep(merged)
  })
}

///|
// Deserializing many Bitmap containers: each container's cardinality is a
// 1024-word popcount, so computing it once instead of twice (validate + store)
// halves that work. The fixture is 32 buckets of 8192 even values each.

///|
test "bench deserialize many bitmap containers" (it : @bench.T) {
  let values : Array[UInt32] = []
  for b = 0; b < 32; b = b + 1 {
    for j = 0; j < 8192; j = j + 1 {
      values.push((b * 65536 + j * 2).reinterpret_as_uint())
    }
  }
  let bytes = @moonbit-roaring.RoaringBitmap::from_array(values).serialize()
  it.keep(bytes)
  it.bench(fn() {
    let bm = @moonbit-roaring.RoaringBitmap::deserialize(bytes)
    it.keep(bm)
  })
}
