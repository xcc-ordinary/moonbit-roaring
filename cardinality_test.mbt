// Tests for the cardinality-only set operations.
//
// The invariant under test is that each `*_cardinality` method agrees with
// its materializing counterpart, so the tests deliberately pair them rather
// than hard-coding expected counts: a disagreement means the counting merge
// diverged from the real one.
//
// The public methods return `Int64` because a bitmap can hold up to 2^32
// values, which does not fit in MoonBit's 32-bit signed `Int`. Comparing
// against a materialized `.size()` therefore has to widen explicitly.

///|
/// `count` values starting at `offset`, stepping by two. Striding by two is
/// what defeats run-length encoding, which is how a test forces the Bitmap
/// container representation instead of getting a Run for free.
fn strided_values(count : Int32, offset : Int32) -> Array[UInt32] {
  Array::makei(count, i => (offset + i * 2).reinterpret_as_uint())
}

///|
/// Every cardinality method must report the size of the bitmap the
/// corresponding materializing operation would have built.
fn assert_cardinality_agrees(
  a : @moonbit-roaring.RoaringBitmap,
  b : @moonbit-roaring.RoaringBitmap,
) -> Unit raise {
  assert_eq(a.and_cardinality(b), a.intersect(b).size())
  assert_eq(a.or_cardinality(b), a.union(b).size())
  assert_eq(a.andnot_cardinality(b), a.difference(b).size())
  assert_eq(a.xor_cardinality(b), a.xor(b).size())
}

///|
test "cardinality agrees with materializing operations on sparse data" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U, 1000U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 3U, 4U, 1001U])
  assert_cardinality_agrees(a, b)
  assert_eq(a.and_cardinality(b), 2L)
  assert_eq(a.or_cardinality(b), 6L)
  assert_eq(a.andnot_cardinality(b), 2L)
  assert_eq(a.xor_cardinality(b), 4L)
}

///|
test "cardinality agrees across bucket boundaries" {
  // Keys 0, 1 and 3 on the left; 1, 2 and 3 on the right, so every branch of
  // the container-key merge walk is taken at least once.
  let a = @moonbit-roaring.RoaringBitmap::from_array([
    1U, 65537U, 200000U, 200001U,
  ])
  let b = @moonbit-roaring.RoaringBitmap::from_array([65537U, 131073U, 200000U])
  assert_cardinality_agrees(a, b)
}

///|
test "cardinality agrees on disjoint bitmaps" {
  let a = @moonbit-roaring.RoaringBitmap::from_range(0U, 100U)
  let b = @moonbit-roaring.RoaringBitmap::from_range(1000U, 1100U)
  assert_cardinality_agrees(a, b)
  assert_eq(a.and_cardinality(b), 0L)
  assert_eq(a.or_cardinality(b), 200L)
  assert_eq(a.andnot_cardinality(b), 100L)
  assert_eq(a.xor_cardinality(b), 200L)
}

///|
test "cardinality handles empty operands" {
  let empty = @moonbit-roaring.RoaringBitmap::new()
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 65536U])
  assert_cardinality_agrees(empty, a)
  assert_cardinality_agrees(a, empty)
  assert_cardinality_agrees(empty, empty)
  assert_eq(empty.or_cardinality(a), 3L)
  assert_eq(a.andnot_cardinality(empty), 3L)
  assert_eq(a.and_cardinality(empty), 0L)
}

///|
test "cardinality agrees on dense bitmap containers" {
  // A consecutive range always collapses to a single cheap Run, so dense
  // Bitmap containers need strided data instead: every other value is far
  // too fragmented to run-length encode, and past 4096 values the array
  // encoding costs more than the 8KB bitmap.
  let a = @moonbit-roaring.RoaringBitmap::from_array(strided_values(20000, 0))
  let b = @moonbit-roaring.RoaringBitmap::from_array(
    strided_values(20000, 10000),
  )
  assert_eq(a.get_stats().bitmap_containers, 1)
  assert_eq(a.get_stats().array_containers, 0)
  assert_eq(b.get_stats().bitmap_containers, 1)
  assert_cardinality_agrees(a, b)
  // a = even values in [0, 40000), b = even values in [10000, 50000).
  assert_eq(a.and_cardinality(b), 15000L)
  assert_eq(a.or_cardinality(b), 25000L)
  assert_eq(a.andnot_cardinality(b), 5000L)
  assert_eq(a.xor_cardinality(b), 10000L)
}

///|
test "cardinality agrees on run containers" {
  // Consecutive ranges collapse to Run containers; counting must still match.
  // Both ranges are kept inside bucket 0 so each bitmap is exactly one Run.
  let a = @moonbit-roaring.RoaringBitmap::from_range(0U, 50000U)
  let b = @moonbit-roaring.RoaringBitmap::from_range(25000U, 60000U)
  assert_eq(a.get_stats().run_containers, 1)
  assert_eq(b.get_stats().run_containers, 1)
  assert_cardinality_agrees(a, b)
  assert_eq(a.and_cardinality(b), 25000L)
  assert_eq(a.or_cardinality(b), 60000L)
  assert_eq(a.andnot_cardinality(b), 25000L)
  assert_eq(a.xor_cardinality(b), 35000L)
}

///|
test "cardinality agrees on mixed container types" {
  // Array on one side, Bitmap on the other, Run on a third: the generic
  // array-decode path handles every combination.
  let sparse = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U, 15000U])
  let dense = @moonbit-roaring.RoaringBitmap::from_range(0U, 20000U)
  let runs = @moonbit-roaring.RoaringBitmap::from_range(10000U, 60000U)
  assert_cardinality_agrees(sparse, dense)
  assert_cardinality_agrees(sparse, runs)
  assert_cardinality_agrees(dense, runs)
  assert_cardinality_agrees(dense, dense)
}

///|
test "cardinality is symmetric for and, or and xor" {
  let a = @moonbit-roaring.RoaringBitmap::from_range(0U, 30000U)
  let b = @moonbit-roaring.RoaringBitmap::from_range(10000U, 50000U)
  assert_eq(a.and_cardinality(b), b.and_cardinality(a))
  assert_eq(a.or_cardinality(b), b.or_cardinality(a))
  assert_eq(a.xor_cardinality(b), b.xor_cardinality(a))
  // andnot is the one directional operation.
  assert_eq(a.andnot_cardinality(b), 10000L)
  assert_eq(b.andnot_cardinality(a), 20000L)
}

///|
test "cardinality matches rank at the maximum element" {
  // rank(max) is defined to equal size; the same identity must hold through
  // the union cardinality of a bitmap with itself.
  let a = @moonbit-roaring.RoaringBitmap::from_array([5U, 6U, 70000U])
  assert_eq(a.or_cardinality(a), a.size())
  assert_eq(a.and_cardinality(a), a.size())
  assert_eq(a.xor_cardinality(a), 0L)
  assert_eq(a.andnot_cardinality(a), 0L)
}

///|
test "cardinality stays exact past the 32-bit Int range" {
  // 2^32 values is the whole representable universe and does not fit in a
  // 32-bit signed Int, which is exactly why these methods return Int64.
  // `add_range` makes such a bitmap cheap to build, so this is reachable in
  // one call rather than being a theoretical extreme.
  //
  // The two halves use disjoint container-key ranges, so the merge walk only
  // ever takes the "key on one side only" branch and reads the cached
  // cardinality. Comparing a bitmap against itself would instead decode all
  // 65536 containers, which is a different (and much slower) code path.
  let low = @moonbit-roaring.RoaringBitmap::new().add_range(0U, 2147483648U)
  let high = @moonbit-roaring.RoaringBitmap::new()
    .add_range(2147483648U, 4294967295U)
    .add(4294967295U)
  assert_eq(low.or_cardinality(high), 4294967296L)
  assert_eq(low.xor_cardinality(high), 4294967296L)
  assert_eq(low.and_cardinality(high), 0L)
  assert_eq(low.andnot_cardinality(high), 2147483648L)
  assert_eq(high.andnot_cardinality(low), 2147483648L)
  // Disjoint sets must report 0 similarity, not the "both empty" sentinel.
  assert_eq(low.jaccard_similarity(high), 0.0)
}

///|
test "is_subset is exact past the 32-bit Int range" {
  // A count-based subset test would compute |A \ B|, which wraps past 2^31
  // and turns "not a subset" into a false positive.
  let everything = @moonbit-roaring.RoaringBitmap::new()
    .add_range(0U, 2147483648U)
    .add_range(2147483648U, 4294967295U)
    .add(4294967295U)
  let empty = @moonbit-roaring.RoaringBitmap::new()
  assert_false(everything.is_subset(empty))
  assert_true(empty.is_subset(everything))
  assert_true(empty.is_subset(empty))
}

///|
test "is_subset uses direct containment" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U, 4U])
  assert_true(a.is_subset(b))
  assert_false(b.is_subset(a))
  assert_true(a.is_subset(a))
  assert_true(
    @moonbit-roaring.RoaringBitmap::new().is_subset(
      @moonbit-roaring.RoaringBitmap::new(),
    ),
  )
  // Cross-bucket and dense subsets must behave identically.
  let dense = @moonbit-roaring.RoaringBitmap::from_range(0U, 40000U)
  let wider = @moonbit-roaring.RoaringBitmap::from_range(0U, 50000U)
  assert_true(dense.is_subset(wider))
  assert_false(wider.is_subset(dense))
}

///|
test "is_subset compares Bitmap containers a word at a time" {
  // Strided data defeats run-length encoding, so both sides are Bitmap
  // containers and the word-level fast path is what runs. Correctness here is
  // the same as for any other representation: a is a subset of b exactly when
  // every strided value of a is also strided in b.
  let a = @moonbit-roaring.RoaringBitmap::from_array(strided_values(20000, 0))
  let b = @moonbit-roaring.RoaringBitmap::from_array(strided_values(30000, 0))
  assert_eq(a.get_stats().bitmap_containers, 1)
  assert_eq(b.get_stats().bitmap_containers, 1)
  assert_true(a.is_subset(b))
  assert_false(b.is_subset(a))
  // Disjoint strides: a holds even values, c holds odd ones.
  let c = @moonbit-roaring.RoaringBitmap::from_array(strided_values(20000, 1))
  assert_false(a.is_subset(c))
  assert_false(c.is_subset(a))
  assert_true(a.is_subset(a))
}

///|
test "is_subset agrees with the cardinality test on Bitmap containers" {
  let a = @moonbit-roaring.RoaringBitmap::from_array(strided_values(12000, 0))
  let b = @moonbit-roaring.RoaringBitmap::from_array(strided_values(18000, 0))
  // andnot_cardinality == 0 is the definition; the containment walk has to
  // reach the same verdict without counting.
  assert_eq(a.is_subset(b), a.andnot_cardinality(b) == 0L)
  assert_eq(b.is_subset(a), b.andnot_cardinality(a) == 0L)
}

///|
test "intersects agrees with and_cardinality on randomized pairs" {
  // The merge walk in `intersects` has three branches, and a wrong index
  // update in any of them still compiles. Pairing it against the counting
  // version catches that — as a hang rather than a wrong verdict, since a
  // backwards index update makes the walk fail to terminate.
  let mut seed = 3131
  for _trial = 0; _trial < 40; _trial = _trial + 1 {
    seed = range_lcg(seed)
    let count_a = 1 + seed % 100
    let values_a = []
    for _i = 0; _i < count_a; _i = _i + 1 {
      seed = range_lcg(seed)
      values_a.push((seed % 500000).reinterpret_as_uint())
    }
    seed = range_lcg(seed)
    let count_b = 1 + seed % 100
    let values_b = []
    for _i = 0; _i < count_b; _i = _i + 1 {
      seed = range_lcg(seed)
      values_b.push((seed % 500000).reinterpret_as_uint())
    }
    let a = @moonbit-roaring.RoaringBitmap::from_array(values_a)
    let b = @moonbit-roaring.RoaringBitmap::from_array(values_b)
    assert_eq(a.intersects(b), b.intersects(a))
    assert_eq(a.intersects(b), a.and_cardinality(b) > 0L)
  }
}

///|
test "intersects is true exactly when the sets overlap" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 70000U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 3U, 140000U])
  let c = @moonbit-roaring.RoaringBitmap::from_array([4U, 140000U])
  assert_true(a.intersects(b))
  assert_true(b.intersects(a))
  assert_false(a.intersects(c))
  assert_false(c.intersects(a))
  assert_true(a.intersects(a))
  assert_false(@moonbit-roaring.RoaringBitmap::new().intersects(a))
  assert_false(a.intersects(@moonbit-roaring.RoaringBitmap::new()))
  // Same bucket, no shared value.
  let dense_a = @moonbit-roaring.RoaringBitmap::from_array(
    bitmap_container_values(9000, 0),
  )
  let dense_b = @moonbit-roaring.RoaringBitmap::from_array(
    bitmap_container_values(9000, 1),
  )
  assert_false(dense_a.intersects(dense_b))
}
