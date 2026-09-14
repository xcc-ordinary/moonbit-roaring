// Tests for add_range/remove_range/contains_range/from_range.

// ============ add_range: full-bucket fast path ============

///|
test "add_range covering exactly one bucket becomes a single Run" {
  let bm = RoaringBitmap::from_range(0U, 65536U)
  assert_eq(bm.size(), 65536)
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 1)
  assert_eq(stats.run_containers, 1)
  assert_true(bm.contains(0U))
  assert_true(bm.contains(65535U))
}

///|
test "add_range spanning several full buckets stays cheap" {
  let bm = RoaringBitmap::from_range(0U, 5U * 65536U)
  assert_eq(bm.size(), 5 * 65536)
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 5)
  assert_eq(stats.run_containers, 5)
  // Five runs at 4 bytes each: nowhere close to paying for 5 Bitmaps (40KB).
  assert_true(stats.total_bytes_used < 100)
}

///|
test "add_range with partial buckets on both ends" {
  // Bucket 0: values [60000, 65535]; bucket 1 (full): [65536, 131071];
  // bucket 2: values [131072, 131200].
  let bm = RoaringBitmap::from_range(60000U, 131201U)
  assert_eq(bm.size(), 131201 - 60000)
  assert_true(bm.contains(60000U))
  assert_true(bm.contains(65535U))
  assert_true(bm.contains(65536U))
  assert_true(bm.contains(131071U))
  assert_true(bm.contains(131200U))
  assert_false(bm.contains(59999U))
  assert_false(bm.contains(131201U))
}

///|
test "add_range merges into an existing sparse bucket" {
  let bm = RoaringBitmap::from_array([1U, 2U, 100U]).add_range(10U, 20U)
  assert_true(bm.contains(1U))
  assert_true(bm.contains(2U))
  assert_true(bm.contains(100U))
  for i = 10; i < 20; i = i + 1 {
    assert_true(bm.contains(i.reinterpret_as_uint()))
  }
  assert_eq(bm.size(), 3 + 10)
}

///|
test "add_range is idempotent on overlapping calls" {
  let bm = RoaringBitmap::new().add_range(0U, 100U).add_range(50U, 150U)
  assert_eq(bm.size(), 150)
  assert_true(bm.contains_range(0U, 150U))
}

///|
test "add_range with start >= end is a no-op" {
  let bm = RoaringBitmap::from_array([1U, 2U]).add_range(50U, 50U)
  assert_eq(bm.size(), 2)
  let bm2 = RoaringBitmap::from_array([1U, 2U]).add_range(50U, 10U)
  assert_eq(bm2.size(), 2)
}

///|
test "add_range single-element range behaves like add" {
  let bm = RoaringBitmap::new().add_range(41U, 42U)
  assert_eq(bm.to_array(), [41U])
}

// ============ remove_range ============

///|
test "remove_range covering exactly one bucket drops the container" {
  let bm = RoaringBitmap::from_range(0U, 131072U).remove_range(0U, 65536U)
  assert_eq(bm.size(), 65536)
  assert_eq(bm.get_stats().total_containers, 1)
  assert_false(bm.contains(0U))
  assert_false(bm.contains(65535U))
  assert_true(bm.contains(65536U))
}

///|
test "remove_range punching a hole in the middle of a bucket" {
  let bm = RoaringBitmap::from_range(0U, 100U).remove_range(30U, 60U)
  assert_eq(bm.size(), 100 - 30)
  for i = 0; i < 30; i = i + 1 {
    assert_true(bm.contains(i.reinterpret_as_uint()))
  }
  for i = 30; i < 60; i = i + 1 {
    assert_false(bm.contains(i.reinterpret_as_uint()))
  }
  for i = 60; i < 100; i = i + 1 {
    assert_true(bm.contains(i.reinterpret_as_uint()))
  }
}

///|
test "remove_range removing everything empties the bitmap" {
  let bm = RoaringBitmap::from_range(0U, 10000U).remove_range(0U, 10000U)
  assert_true(bm.is_empty())
}

///|
test "remove_range on a non-existent bucket is a no-op" {
  let bm = RoaringBitmap::from_array([1U, 2U]).remove_range(100000U, 200000U)
  assert_eq(bm.to_array(), [1U, 2U])
}

///|
test "remove_range with start >= end is a no-op" {
  let bm = RoaringBitmap::from_array([1U, 2U]).remove_range(50U, 50U)
  assert_eq(bm.size(), 2)
}

// ============ contains_range ============

///|
test "contains_range true for a fully covered run container" {
  let bm = RoaringBitmap::from_range(1000U, 2000U)
  assert_true(bm.contains_range(1000U, 2000U))
  assert_true(bm.contains_range(1500U, 1600U))
  assert_false(bm.contains_range(999U, 2000U))
  assert_false(bm.contains_range(1000U, 2001U))
}

///|
test "contains_range true for a fully covered array container" {
  let bm = RoaringBitmap::from_array([5U, 6U, 7U, 8U, 100U])
  assert_true(bm.contains_range(5U, 9U))
  assert_false(bm.contains_range(5U, 10U))
  assert_false(bm.contains_range(4U, 9U))
}

///|
test "contains_range on a bitmap container checks bit-level coverage" {
  // Even numbers 0..16382: scattered (not consecutive, so this stays a
  // Bitmap rather than collapsing to a cheaper Run).
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  // A single value is trivially a "range" of length 1.
  assert_true(bm.contains_range(100U, 101U))
  // Odd numbers are absent, so a 2-wide range starting on an even value
  // (which includes the following odd value) is not fully covered.
  assert_false(bm.contains_range(100U, 102U))
}

///|
test "contains_range false when bucket is missing" {
  let bm = RoaringBitmap::from_array([1U])
  assert_false(bm.contains_range(70000U, 70010U))
}

///|
test "contains_range spans multiple buckets" {
  let bm = RoaringBitmap::from_range(60000U, 131201U)
  assert_true(bm.contains_range(60000U, 131201U))
  assert_false(bm.contains_range(59999U, 131201U))
}

///|
test "contains_range with start >= end is trivially true" {
  let bm = RoaringBitmap::new()
  assert_true(bm.contains_range(5U, 5U))
  assert_true(bm.contains_range(5U, 0U))
}

// ============ from_range ============

///|
test "from_range constructs the same bitmap as new + add_range" {
  let a = RoaringBitmap::from_range(100U, 200U)
  let b = RoaringBitmap::new().add_range(100U, 200U)
  assert_true(a.equals(b))
}
