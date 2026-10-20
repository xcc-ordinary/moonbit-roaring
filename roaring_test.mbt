// Blackbox tests for the public RoaringBitmap API.

// ============ Basic construction and membership ============

///|
test "new bitmap is empty" {
  let bm = @moonbit-roaring.RoaringBitmap::new()
  assert_true(bm.is_empty())
  assert_eq(bm.size(), 0)
}

///|
test "singleton contains exactly one value" {
  let bm = @moonbit-roaring.RoaringBitmap::singleton(42U)
  assert_true(bm.contains(42U))
  assert_false(bm.contains(43U))
  assert_eq(bm.size(), 1)
}

///|
test "add is idempotent" {
  let bm = @moonbit-roaring.RoaringBitmap::new().add(5U).add(5U).add(5U)
  assert_eq(bm.size(), 1)
  assert_true(bm.contains(5U))
}

///|
test "add multiple distinct values" {
  let bm = @moonbit-roaring.RoaringBitmap::new().add(1U).add(2U).add(3U)
  assert_eq(bm.size(), 3)
  assert_true(bm.contains(1U))
  assert_true(bm.contains(2U))
  assert_true(bm.contains(3U))
  assert_false(bm.contains(4U))
}

///|
test "remove existing value" {
  let bm = @moonbit-roaring.RoaringBitmap::new().add(1U).add(2U).remove(1U)
  assert_eq(bm.size(), 1)
  assert_false(bm.contains(1U))
  assert_true(bm.contains(2U))
}

///|
test "remove non-existing value is a no-op" {
  let bm = @moonbit-roaring.RoaringBitmap::new().add(1U).remove(999U)
  assert_eq(bm.size(), 1)
  assert_true(bm.contains(1U))
}

///|
test "remove last element empties bitmap" {
  let bm = @moonbit-roaring.RoaringBitmap::new().add(7U).remove(7U)
  assert_true(bm.is_empty())
  assert_false(bm.contains(7U))
}

///|
test "from_array deduplicates" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 2U, 3U, 1U])
  assert_eq(bm.size(), 3)
}

///|
test "min and max on empty bitmap" {
  let bm = @moonbit-roaring.RoaringBitmap::new()
  assert_true(bm.min() is None)
  assert_true(bm.max() is None)
}

///|
test "min and max on populated bitmap" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([50U, 10U, 30U])
  assert_eq(bm.min(), Some(10U))
  assert_eq(bm.max(), Some(50U))
}

// ============ Cross-bucket behavior (values spanning high 16 bits) ============

///|
test "values across high-16-bit boundary are both stored" {
  // 65535 is the max low-16 value in bucket 0; 65536 is the min value in bucket 1.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([65535U, 65536U])
  assert_eq(bm.size(), 2)
  assert_true(bm.contains(65535U))
  assert_true(bm.contains(65536U))
  assert_eq(bm.get_stats().total_containers, 2)
}

///|
test "large value near UInt32 max round-trips" {
  let big : UInt32 = 4294967295U // 2^32 - 1
  let bm = @moonbit-roaring.RoaringBitmap::singleton(big)
  assert_true(bm.contains(big))
  assert_eq(bm.to_array(), [big])
}

// ============ to_array ordering ============

///|
test "to_array returns sorted values" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([300U, 1U, 200U, 100U])
  assert_eq(bm.to_array(), [1U, 100U, 200U, 300U])
}

// ============ Container auto-optimization: THE core differentiator ============

///|
test "sparse values stay in an Array container" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 1000U, 50000U])
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.run_containers, 0)
  assert_eq(stats.bitmap_containers, 0)
}

///|
test "consecutive range converts to a Run container" {
  let mut bm = @moonbit-roaring.RoaringBitmap::new()
  let values = []
  for i = 0; i < 10000; i = i + 1 {
    values.push(i.reinterpret_as_uint())
  }
  bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(bm.size(), 10000)
  assert_eq(stats.run_containers, 1)
  assert_eq(stats.array_containers, 0)
  assert_eq(stats.bitmap_containers, 0)
  // A single run costs 4 bytes; must be far smaller than the 8KB bitmap
  // fallback the existing ecosystem implementation would have used.
  assert_true(stats.total_bytes_used < 100)
}

///|
test "dense random-ish values convert to a Bitmap container" {
  // Even numbers from 0 to 16382 (8192 values): scattered (not consecutive,
  // so Run gives no benefit) and 8192 * 2 = 16384 bytes as an Array, which
  // is clearly worse than the fixed 8192-byte Bitmap encoding.
  let mut bm = @moonbit-roaring.RoaringBitmap::new()
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(bm.size(), 8192)
  assert_eq(stats.bitmap_containers, 1)
}

///|
test "removing values from a run breaks it back into array when cheaper" {
  let mut bm = @moonbit-roaring.RoaringBitmap::new()
  let values = []
  for i = 0; i < 20; i = i + 1 {
    values.push(i.reinterpret_as_uint())
  }
  bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  // Remove every other element to destroy the consecutive run.
  for i = 1; i < 20; i = i + 2 {
    bm = bm.remove(i.reinterpret_as_uint())
  }
  assert_eq(bm.size(), 10)
  let stats = bm.get_stats()
  // 10 scattered single-value "runs" (10 runs x 4 bytes = 40) vs
  // 10 array entries (10 x 2 bytes = 20): array should win now.
  assert_eq(stats.array_containers, 1)
}

// ============ Set operations ============

///|
test "union combines two disjoint sets" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([4U, 5U])
  let result = a.union(b)
  assert_eq(result.to_array(), [1U, 2U, 3U, 4U, 5U])
}

///|
test "union deduplicates overlapping values" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 3U, 4U])
  let result = a.union(b)
  assert_eq(result.to_array(), [1U, 2U, 3U, 4U])
}

///|
test "intersect keeps only common values" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U, 4U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 4U, 6U])
  let result = a.intersect(b)
  assert_eq(result.to_array(), [2U, 4U])
}

///|
test "intersect with disjoint sets is empty" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([3U, 4U])
  let result = a.intersect(b)
  assert_true(result.is_empty())
}

///|
test "difference removes elements present in other" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U, 4U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 4U])
  let result = a.difference(b)
  assert_eq(result.to_array(), [1U, 3U])
}

///|
test "xor keeps values unique to each side" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 3U, 4U])
  let result = a.xor(b)
  assert_eq(result.to_array(), [1U, 4U])
}

///|
test "set operations across high-16-bit buckets" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 70000U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([70000U, 200000U])
  assert_eq(a.union(b).to_array(), [1U, 70000U, 200000U])
  assert_eq(a.intersect(b).to_array(), [70000U])
  assert_eq(a.difference(b).to_array(), [1U])
}

///|
test "union with empty bitmap is identity" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let empty = @moonbit-roaring.RoaringBitmap::new()
  assert_eq(a.union(empty).to_array(), a.to_array())
}

// ============ Comparison ============

///|
test "equals compares by content not structure" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([3U, 2U, 1U])
  assert_true(a.equals(b))
}

///|
test "equals detects differing content" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 4U])
  assert_false(a.equals(b))
}

///|
test "is_subset detects true subset" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  assert_true(a.is_subset(b))
  assert_false(b.is_subset(a))
}

// ============ Set operations: the "other side leads" merge branches ============
//
// The merge walk in each set operation has three arms (a.key < b.key,
// a.key > b.key, keys equal). Tests above mostly drive the first and third;
// these pin down the arm where `other` holds the earlier bucket, plus the
// tail drain of each side.

///|
test "set operations when other holds the earlier bucket" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([200000U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([1U])
  assert_eq(a.union(b).to_array(), [1U, 200000U])
  assert_eq(a.xor(b).to_array(), [1U, 200000U])
  assert_eq(a.difference(b).to_array(), [200000U])
  assert_true(a.intersect(b).is_empty())
}

///|
test "set operations when other leads within a shared bucket" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([10U, 20U, 30U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([5U, 20U, 25U])
  assert_eq(a.intersect(b).to_array(), [20U])
  assert_eq(a.difference(b).to_array(), [10U, 30U])
  assert_eq(a.xor(b).to_array(), [5U, 10U, 25U, 30U])
}

///|
test "xor drains both tails when bucket counts differ" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 70000U, 140000U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([70000U])
  assert_eq(a.xor(b).to_array(), [1U, 140000U])
  assert_eq(b.xor(a).to_array(), [1U, 140000U])
}

// ============ min / max across container types ============

///|
test "min and max on a run container" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(100U, 200U)
  assert_eq(bm.get_stats().run_containers, 1)
  assert_eq(bm.min(), Some(100U))
  assert_eq(bm.max(), Some(199U))
}

///|
test "min and max on a bitmap container" {
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  assert_eq(bm.min(), Some(0U))
  assert_eq(bm.max(), Some(16382U))
}

// ============ Bucket insertion order ============

///|
test "add inserts a new bucket before an existing higher one" {
  let bm = @moonbit-roaring.RoaringBitmap::singleton(200000U).add(5U)
  assert_eq(bm.to_array(), [5U, 200000U])
  assert_eq(bm.get_stats().total_containers, 2)
}

///|
test "add_many merges into an already-existing bucket" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U]).add_many([
    3U, 4U, 100U,
  ])
  assert_eq(bm.to_array(), [1U, 2U, 3U, 4U, 100U])
}

///|
test "add_many creates a bucket ahead of existing higher buckets" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([200000U]).add_many([
    5U, 6U,
  ])
  assert_eq(bm.to_array(), [5U, 6U, 200000U])
}

// ============ Multi-way set operations ============

///|
test "union_all of an empty array is an empty bitmap" {
  let result = @moonbit-roaring.RoaringBitmap::union_all([])
  assert_true(result.is_empty())
}

///|
test "union_all of a single bitmap returns its contents" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let result = @moonbit-roaring.RoaringBitmap::union_all([a])
  assert_eq(result.to_array(), [1U, 2U, 3U])
}

///|
test "union_all merges several bitmaps across container types" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U])
  let b = @moonbit-roaring.RoaringBitmap::from_range(100U, 200U)
  let c = @moonbit-roaring.RoaringBitmap::from_array([2U, 300000U])
  let result = @moonbit-roaring.RoaringBitmap::union_all([a, b, c])
  assert_eq(result.size(), 2 + 100 + 1)
  assert_true(result.contains(1U))
  assert_true(result.contains(150U))
  assert_true(result.contains(300000U))
}

///|
test "intersect_all of an empty array is an empty bitmap" {
  let result = @moonbit-roaring.RoaringBitmap::intersect_all([])
  assert_true(result.is_empty())
}

///|
test "intersect_all of a single bitmap returns its contents" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let result = @moonbit-roaring.RoaringBitmap::intersect_all([a])
  assert_eq(result.to_array(), [1U, 2U, 3U])
}

///|
test "intersect_all keeps only values common to every bitmap" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U, 4U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 3U, 4U, 5U])
  let c = @moonbit-roaring.RoaringBitmap::from_array([3U, 4U, 5U, 6U])
  let result = @moonbit-roaring.RoaringBitmap::intersect_all([a, b, c])
  assert_eq(result.to_array(), [3U, 4U])
}

///|
test "intersect_all is empty when any bitmap is disjoint from the rest" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let c = @moonbit-roaring.RoaringBitmap::from_array([100U])
  let result = @moonbit-roaring.RoaringBitmap::intersect_all([a, b, c])
  assert_true(result.is_empty())
}

// ============ add_many: batch construction ============
//
// add_many sorts its input and merges each bucket once. The tests below pin
// that behaviour against the naive fold of single `add` calls, which is the
// reference the batch path has to match exactly — including the serialized
// bytes, so a difference in container selection would show up here too.

///|
/// A small deterministic generator, so these tests do not depend on
/// `Math.random` (unavailable here) and stay reproducible.
fn batch_lcg(seed : Int32) -> Int32 {
  let raw = seed * 1103515245 + 12345
  if raw < 0 {
    -raw % 1000000
  } else {
    raw % 1000000
  }
}

///|
test "add_many matches folding add over randomized inputs" {
  let mut seed = 7
  for _trial = 0; _trial < 25; _trial = _trial + 1 {
    let count = 1 + batch_lcg(seed) % 300
    seed = batch_lcg(seed)
    let values = []
    for _i = 0; _i < count; _i = _i + 1 {
      seed = batch_lcg(seed)
      values.push((seed % 300000).reinterpret_as_uint())
    }
    let via_many = @moonbit-roaring.RoaringBitmap::from_array(values)
    let mut via_add = @moonbit-roaring.RoaringBitmap::new()
    for v in values {
      via_add = via_add.add(v)
    }
    assert_eq(via_many.to_array(), via_add.to_array())
    assert_eq(via_many.size(), via_add.size())
    assert_eq(via_many.serialize(), via_add.serialize())
  }
}

///|
test "add_many matches folding add on top of an existing bitmap" {
  let mut seed = 99
  for _trial = 0; _trial < 25; _trial = _trial + 1 {
    let base_count = 1 + batch_lcg(seed) % 150
    seed = batch_lcg(seed)
    let base = []
    for _i = 0; _i < base_count; _i = _i + 1 {
      seed = batch_lcg(seed)
      base.push((seed % 300000).reinterpret_as_uint())
    }
    let extra_count = 1 + batch_lcg(seed) % 300
    seed = batch_lcg(seed)
    let extra = []
    for _i = 0; _i < extra_count; _i = _i + 1 {
      seed = batch_lcg(seed)
      extra.push((seed % 300000).reinterpret_as_uint())
    }
    let start = @moonbit-roaring.RoaringBitmap::from_array(base)
    let via_many = start.add_many(extra)
    let mut via_add = start
    for v in extra {
      via_add = via_add.add(v)
    }
    assert_eq(via_many.to_array(), via_add.to_array())
    assert_eq(via_many.serialize(), via_add.serialize())
    assert_eq(
      via_many.get_stats().total_containers,
      via_add.get_stats().total_containers,
    )
  }
}

///|
test "add_many is idempotent and collapses duplicates" {
  let values = [1U, 2U, 2U, 3U, 1U, 70000U, 70000U]
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.to_array(), [1U, 2U, 3U, 70000U])
  assert_eq(bm.add_many(values).to_array(), bm.to_array())
  assert_eq(bm.add_many([]).to_array(), bm.to_array())
  assert_eq(bm.add_many([1U, 1U, 1U]).to_array(), bm.to_array())
}

///|
test "add_many spreads one value per bucket across many containers" {
  // 20000 distinct high keys, one value each: the shape that used to rebuild
  // the container list once per new bucket.
  let values = Array::makei(20000, i => (i * 65536).reinterpret_as_uint())
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.size(), 20000)
  assert_eq(bm.get_stats().total_containers, 20000)
  assert_eq(bm.min(), Some(0U))
  assert_eq(bm.max(), Some((19999 * 65536).reinterpret_as_uint()))
}

// ============ content equality across representations ============

///|
/// Build portable bytes that store `count` consecutive values in one bucket as
/// an ARRAY container. `from_range` of the same values produces a Run, so this
/// is how a test gets two bitmaps with identical content but different
/// internal layout — the case `equals` exists for.
fn array_container_bytes(count : Int32) -> Bytes {
  let buf = @buffer.Buffer::Buffer()
  buf.write_uint_le(12346U) // no-run cookie
  buf.write_uint_le(1U) // one container
  buf.write_uint16_le((0 : UInt16)) // key 0
  buf.write_uint16_le((count - 1).to_uint16()) // cardinality - 1
  // cookie + count + descriptive header + offset header
  buf.write_uint_le((8 + 8).reinterpret_as_uint())
  for i = 0; i < count; i = i + 1 {
    buf.write_uint16_le(i.to_uint16())
  }
  buf.to_bytes()
}

///|
test "equals compares content, not container layout" {
  let canonical = @moonbit-roaring.RoaringBitmap::from_range(0U, 4096U)
  let as_array = match
    @moonbit-roaring.RoaringBitmap::deserialize(array_container_bytes(4096)) {
    Ok(b) => b
    Err(e) => {
      println("fixture rejected: \{e}")
      panic()
    }
  }
  // Same values, deliberately different representations.
  assert_eq(canonical.get_stats().run_containers, 1)
  assert_eq(as_array.get_stats().array_containers, 1)
  assert_eq(canonical.to_array(), as_array.to_array())
  assert_true(canonical.equals(as_array))
  assert_true(as_array.equals(canonical))
  assert_true(canonical.equals(canonical))
}

///|
test "equals rejects different content at the same cardinality" {
  let a = @moonbit-roaring.RoaringBitmap::from_range(0U, 4096U)
  let b = @moonbit-roaring.RoaringBitmap::from_range(1U, 4097U)
  assert_eq(a.size(), b.size())
  assert_false(a.equals(b))
  assert_false(b.equals(a))
  assert_false(a.equals(@moonbit-roaring.RoaringBitmap::new()))
  assert_true(
    @moonbit-roaring.RoaringBitmap::new().equals(
      @moonbit-roaring.RoaringBitmap::new(),
    ),
  )
}

///|
test "equals agrees with array comparison on randomized pairs" {
  let mut seed = 4242
  for _trial = 0; _trial < 30; _trial = _trial + 1 {
    seed = batch_lcg(seed)
    let count_a = 1 + seed % 200
    let values_a = []
    for _i = 0; _i < count_a; _i = _i + 1 {
      seed = batch_lcg(seed)
      values_a.push((seed % 200000).reinterpret_as_uint())
    }
    seed = batch_lcg(seed)
    let count_b = 1 + seed % 200
    let values_b = []
    for _i = 0; _i < count_b; _i = _i + 1 {
      seed = batch_lcg(seed)
      values_b.push((seed % 200000).reinterpret_as_uint())
    }
    let a = @moonbit-roaring.RoaringBitmap::from_array(values_a)
    let b = @moonbit-roaring.RoaringBitmap::from_array(values_b)
    assert_eq(a.equals(b), a.to_array() == b.to_array())
  }
}

// ============ min/max and contains on compressed containers ============

///|
/// Enough strided values to force a Bitmap container: consecutive data would
/// collapse to a cheaper Run instead.
fn bitmap_container_values(count : Int32, offset : Int32) -> Array[UInt32] {
  Array::makei(count, i => (offset + i * 2).reinterpret_as_uint())
}

///|
test "min and max read the first and last set bit of a Bitmap container" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array(
    bitmap_container_values(4097, 100),
  )
  assert_eq(bm.get_stats().bitmap_containers, 1)
  assert_eq(bm.min(), Some(100U))
  assert_eq(bm.max(), Some((100 + 4096 * 2).reinterpret_as_uint()))
  // Both edges of the bucket at once.
  let edges = @moonbit-roaring.RoaringBitmap::from_array([0U, 65535U])
  assert_eq(edges.min(), Some(0U))
  assert_eq(edges.max(), Some(65535U))
  // Highest bit of a bucket that is not the last one.
  let top = @moonbit-roaring.RoaringBitmap::new()
    .add_range(0U, 65536U)
    .remove_range(0U, 65535U)
  assert_eq(top.min(), Some(65535U))
  assert_eq(top.max(), Some(65535U))
}

///|
test "contains finds a value inside a Run container without scanning it" {
  // Runs of length three beat both the array and the bitmap encoding, and 1024
  // of them give the membership test something to search. Runs of length two
  // would tie with the array encoding instead, so they are not usable here.
  let values = []
  for k = 0; k < 1024; k = k + 1 {
    let base = k * 10
    values.push(base.reinterpret_as_uint())
    values.push((base + 1).reinterpret_as_uint())
    values.push((base + 2).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().run_containers, 1)
  assert_eq(bm.size(), 3072)
  assert_true(bm.contains(0U))
  assert_true(bm.contains(1U))
  assert_true(bm.contains(2U))
  assert_true(bm.contains(10230U))
  assert_true(bm.contains(10232U))
  assert_false(bm.contains(3U))
  assert_false(bm.contains(5U))
  assert_false(bm.contains(10233U))
  // Every value the bitmap claims to hold must be found, and nothing else.
  for v in bm.to_array() {
    assert_true(bm.contains(v))
  }
}

///|
test "== is set equality, not representation equality" {
  // `RoaringBitmap` does not derive `Eq`. A derived implementation would
  // compare container representations, so a bitmap read from portable bytes
  // its producer left as an Array would not equal the same set built here as
  // a Run — which is exactly the interoperability path. The helper writes
  // 0..count-1, so the canonical side has to match that set.
  let canonical = @moonbit-roaring.RoaringBitmap::from_array([0U, 1U, 2U])
  let foreign = match
    @moonbit-roaring.RoaringBitmap::deserialize(array_container_bytes(3)) {
    Ok(b) => b
    Err(e) => {
      println("fixture rejected: \{e}")
      panic()
    }
  }
  assert_eq(canonical.get_stats().run_containers, 1)
  assert_eq(foreign.get_stats().array_containers, 1)
  assert_true(canonical == foreign)
  assert_true(foreign == canonical)
  assert_true(canonical.equals(foreign))
  // And the negative case still has to hold.
  let other = @moonbit-roaring.RoaringBitmap::from_array([5U, 6U, 8U])
  assert_false(canonical == other)
  assert_false(canonical == @moonbit-roaring.RoaringBitmap::new())
  assert_false(@moonbit-roaring.RoaringBitmap::new() == canonical)
}

///|
test "== agrees with equals on randomized pairs across representations" {
  // Same content, different representations, must compare equal both ways.
  let mut seed = 8080
  for _trial = 0; _trial < 20; _trial = _trial + 1 {
    seed = batch_lcg(seed)
    let count = 1 + seed % 60
    let values = []
    for _i = 0; _i < count; _i = _i + 1 {
      seed = batch_lcg(seed)
      values.push((seed % 5000).reinterpret_as_uint())
    }
    let canonical = @moonbit-roaring.RoaringBitmap::from_array(values)
    // Round-trip through the portable format, which may re-represent it.
    let round_tripped = match
      @moonbit-roaring.RoaringBitmap::deserialize(canonical.serialize()) {
      Ok(b) => b
      Err(_) => {
        println("round trip rejected a valid bitmap")
        panic()
      }
    }
    assert_eq(canonical == round_tripped, canonical.equals(round_tripped))
    assert_true(canonical == round_tripped)
  }
}
