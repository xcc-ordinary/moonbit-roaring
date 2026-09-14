// Blackbox tests for the public RoaringBitmap API.

// ============ Basic construction and membership ============

///|
test "new bitmap is empty" {
  let bm = RoaringBitmap::new()
  assert_true(bm.is_empty())
  assert_eq(bm.size(), 0)
}

///|
test "singleton contains exactly one value" {
  let bm = RoaringBitmap::singleton(42U)
  assert_true(bm.contains(42U))
  assert_false(bm.contains(43U))
  assert_eq(bm.size(), 1)
}

///|
test "add is idempotent" {
  let bm = RoaringBitmap::new().add(5U).add(5U).add(5U)
  assert_eq(bm.size(), 1)
  assert_true(bm.contains(5U))
}

///|
test "add multiple distinct values" {
  let bm = RoaringBitmap::new().add(1U).add(2U).add(3U)
  assert_eq(bm.size(), 3)
  assert_true(bm.contains(1U))
  assert_true(bm.contains(2U))
  assert_true(bm.contains(3U))
  assert_false(bm.contains(4U))
}

///|
test "remove existing value" {
  let bm = RoaringBitmap::new().add(1U).add(2U).remove(1U)
  assert_eq(bm.size(), 1)
  assert_false(bm.contains(1U))
  assert_true(bm.contains(2U))
}

///|
test "remove non-existing value is a no-op" {
  let bm = RoaringBitmap::new().add(1U).remove(999U)
  assert_eq(bm.size(), 1)
  assert_true(bm.contains(1U))
}

///|
test "remove last element empties bitmap" {
  let bm = RoaringBitmap::new().add(7U).remove(7U)
  assert_true(bm.is_empty())
  assert_false(bm.contains(7U))
}

///|
test "from_array deduplicates" {
  let bm = RoaringBitmap::from_array([1U, 2U, 2U, 3U, 1U])
  assert_eq(bm.size(), 3)
}

///|
test "min and max on empty bitmap" {
  let bm = RoaringBitmap::new()
  assert_true(bm.min() is None)
  assert_true(bm.max() is None)
}

///|
test "min and max on populated bitmap" {
  let bm = RoaringBitmap::from_array([50U, 10U, 30U])
  assert_eq(bm.min(), Some(10U))
  assert_eq(bm.max(), Some(50U))
}

// ============ Cross-bucket behavior (values spanning high 16 bits) ============

///|
test "values across high-16-bit boundary are both stored" {
  // 65535 is the max low-16 value in bucket 0; 65536 is the min value in bucket 1.
  let bm = RoaringBitmap::from_array([65535U, 65536U])
  assert_eq(bm.size(), 2)
  assert_true(bm.contains(65535U))
  assert_true(bm.contains(65536U))
  assert_eq(bm.get_stats().total_containers, 2)
}

///|
test "large value near UInt32 max round-trips" {
  let big : UInt = 4294967295U // 2^32 - 1
  let bm = RoaringBitmap::singleton(big)
  assert_true(bm.contains(big))
  assert_eq(bm.to_array(), [big])
}

// ============ to_array ordering ============

///|
test "to_array returns sorted values" {
  let bm = RoaringBitmap::from_array([300U, 1U, 200U, 100U])
  assert_eq(bm.to_array(), [1U, 100U, 200U, 300U])
}

// ============ Container auto-optimization: THE core differentiator ============

///|
test "sparse values stay in an Array container" {
  let bm = RoaringBitmap::from_array([1U, 1000U, 50000U])
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.run_containers, 0)
  assert_eq(stats.bitmap_containers, 0)
}

///|
test "consecutive range converts to a Run container" {
  let mut bm = RoaringBitmap::new()
  let values = []
  for i = 0; i < 10000; i = i + 1 {
    values.push(i.reinterpret_as_uint())
  }
  bm = RoaringBitmap::from_array(values)
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
  let mut bm = RoaringBitmap::new()
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  bm = RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(bm.size(), 8192)
  assert_eq(stats.bitmap_containers, 1)
}

///|
test "removing values from a run breaks it back into array when cheaper" {
  let mut bm = RoaringBitmap::new()
  let values = []
  for i = 0; i < 20; i = i + 1 {
    values.push(i.reinterpret_as_uint())
  }
  bm = RoaringBitmap::from_array(values)
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
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let b = RoaringBitmap::from_array([4U, 5U])
  let result = a.union(b)
  assert_eq(result.to_array(), [1U, 2U, 3U, 4U, 5U])
}

///|
test "union deduplicates overlapping values" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let b = RoaringBitmap::from_array([2U, 3U, 4U])
  let result = a.union(b)
  assert_eq(result.to_array(), [1U, 2U, 3U, 4U])
}

///|
test "intersect keeps only common values" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U, 4U])
  let b = RoaringBitmap::from_array([2U, 4U, 6U])
  let result = a.intersect(b)
  assert_eq(result.to_array(), [2U, 4U])
}

///|
test "intersect with disjoint sets is empty" {
  let a = RoaringBitmap::from_array([1U, 2U])
  let b = RoaringBitmap::from_array([3U, 4U])
  let result = a.intersect(b)
  assert_true(result.is_empty())
}

///|
test "difference removes elements present in other" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U, 4U])
  let b = RoaringBitmap::from_array([2U, 4U])
  let result = a.difference(b)
  assert_eq(result.to_array(), [1U, 3U])
}

///|
test "xor keeps values unique to each side" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let b = RoaringBitmap::from_array([2U, 3U, 4U])
  let result = a.xor(b)
  assert_eq(result.to_array(), [1U, 4U])
}

///|
test "set operations across high-16-bit buckets" {
  let a = RoaringBitmap::from_array([1U, 70000U])
  let b = RoaringBitmap::from_array([70000U, 200000U])
  assert_eq(a.union(b).to_array(), [1U, 70000U, 200000U])
  assert_eq(a.intersect(b).to_array(), [70000U])
  assert_eq(a.difference(b).to_array(), [1U])
}

///|
test "union with empty bitmap is identity" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let empty = RoaringBitmap::new()
  assert_eq(a.union(empty).to_array(), a.to_array())
}

// ============ Comparison ============

///|
test "equals compares by content not structure" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let b = RoaringBitmap::from_array([3U, 2U, 1U])
  assert_true(a.equals(b))
}

///|
test "equals detects differing content" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let b = RoaringBitmap::from_array([1U, 2U, 4U])
  assert_false(a.equals(b))
}

///|
test "is_subset detects true subset" {
  let a = RoaringBitmap::from_array([1U, 2U])
  let b = RoaringBitmap::from_array([1U, 2U, 3U])
  assert_true(a.is_subset(b))
  assert_false(b.is_subset(a))
}

// ============ Multi-way set operations ============

///|
test "union_all of an empty array is an empty bitmap" {
  let result = RoaringBitmap::union_all([])
  assert_true(result.is_empty())
}

///|
test "union_all of a single bitmap returns its contents" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let result = RoaringBitmap::union_all([a])
  assert_eq(result.to_array(), [1U, 2U, 3U])
}

///|
test "union_all merges several bitmaps across container types" {
  let a = RoaringBitmap::from_array([1U, 2U])
  let b = RoaringBitmap::from_range(100U, 200U)
  let c = RoaringBitmap::from_array([2U, 300000U])
  let result = RoaringBitmap::union_all([a, b, c])
  assert_eq(result.size(), 2 + 100 + 1)
  assert_true(result.contains(1U))
  assert_true(result.contains(150U))
  assert_true(result.contains(300000U))
}

///|
test "intersect_all of an empty array is an empty bitmap" {
  let result = RoaringBitmap::intersect_all([])
  assert_true(result.is_empty())
}

///|
test "intersect_all of a single bitmap returns its contents" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let result = RoaringBitmap::intersect_all([a])
  assert_eq(result.to_array(), [1U, 2U, 3U])
}

///|
test "intersect_all keeps only values common to every bitmap" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U, 4U])
  let b = RoaringBitmap::from_array([2U, 3U, 4U, 5U])
  let c = RoaringBitmap::from_array([3U, 4U, 5U, 6U])
  let result = RoaringBitmap::intersect_all([a, b, c])
  assert_eq(result.to_array(), [3U, 4U])
}

///|
test "intersect_all is empty when any bitmap is disjoint from the rest" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let b = RoaringBitmap::from_array([1U, 2U, 3U])
  let c = RoaringBitmap::from_array([100U])
  let result = RoaringBitmap::intersect_all([a, b, c])
  assert_true(result.is_empty())
}
