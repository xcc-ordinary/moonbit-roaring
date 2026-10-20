// Tests for add_range/remove_range/contains_range/from_range.

// ============ add_range: full-bucket fast path ============

///|
test "add_range covering exactly one bucket becomes a single Run" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 65536U)
  assert_eq(bm.size(), 65536)
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 1)
  assert_eq(stats.run_containers, 1)
  assert_true(bm.contains(0U))
  assert_true(bm.contains(65535U))
}

///|
test "add_range spanning several full buckets stays cheap" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 5U * 65536U)
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
  let bm = @moonbit-roaring.RoaringBitmap::from_range(60000U, 131201U)
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
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 100U]).add_range(
    10U, 20U,
  )
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
  let bm = @moonbit-roaring.RoaringBitmap::new()
    .add_range(0U, 100U)
    .add_range(50U, 150U)
  assert_eq(bm.size(), 150)
  assert_true(bm.contains_range(0U, 150U))
}

///|
test "add_range with start >= end is a no-op" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U]).add_range(
    50U, 50U,
  )
  assert_eq(bm.size(), 2)
  let bm2 = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U]).add_range(
    50U, 10U,
  )
  assert_eq(bm2.size(), 2)
}

///|
test "add_range single-element range behaves like add" {
  let bm = @moonbit-roaring.RoaringBitmap::new().add_range(41U, 42U)
  assert_eq(bm.to_array(), [41U])
}

// ============ remove_range ============

///|
test "remove_range covering exactly one bucket drops the container" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 131072U).remove_range(
    0U, 65536U,
  )
  assert_eq(bm.size(), 65536)
  assert_eq(bm.get_stats().total_containers, 1)
  assert_false(bm.contains(0U))
  assert_false(bm.contains(65535U))
  assert_true(bm.contains(65536U))
}

///|
test "remove_range punching a hole in the middle of a bucket" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 100U).remove_range(
    30U, 60U,
  )
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
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 10000U).remove_range(
    0U, 10000U,
  )
  assert_true(bm.is_empty())
}

///|
test "remove_range on a non-existent bucket is a no-op" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U]).remove_range(
    100000U, 200000U,
  )
  assert_eq(bm.to_array(), [1U, 2U])
}

///|
test "remove_range with start >= end is a no-op" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U]).remove_range(
    50U, 50U,
  )
  assert_eq(bm.size(), 2)
}

// ============ contains_range ============

///|
test "contains_range true for a fully covered run container" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(1000U, 2000U)
  assert_true(bm.contains_range(1000U, 2000U))
  assert_true(bm.contains_range(1500U, 1600U))
  assert_false(bm.contains_range(999U, 2000U))
  assert_false(bm.contains_range(1000U, 2001U))
}

///|
test "contains_range on a genuine array container" {
  // Mostly-isolated values: one 2-long run plus five singletons costs
  // 6 runs * 4 = 24 bytes as Run vs 7 * 2 = 14 bytes as Array, so this
  // stays an Array container and exercises the binary-search branch.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([
    5U, 6U, 20U, 40U, 60U, 80U, 100U,
  ])
  assert_eq(bm.get_stats().array_containers, 1)
  assert_eq(bm.get_stats().run_containers, 0)
  // The [5, 6] pair is fully present; extending to 7 is not.
  assert_true(bm.contains_range(5U, 7U))
  assert_false(bm.contains_range(5U, 8U))
  // A single isolated value is a range of length 1.
  assert_true(bm.contains_range(20U, 21U))
  // 19 is absent, so a range starting there is not covered.
  assert_false(bm.contains_range(19U, 21U))
  // A range starting past the maximum finds no lower bound at all.
  assert_false(bm.contains_range(200U, 201U))
}

///|
test "contains_range on a multi-run container" {
  // Two separate runs ([5,8] and [100,102]) cost 2 * 4 = 8 bytes as Run
  // vs 8 * 2 = 16 as Array, so this collapses to a Run container. A range
  // is covered only if a single run contains it end to end.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([
    5U, 6U, 7U, 8U, 100U, 101U, 102U,
  ])
  assert_eq(bm.get_stats().run_containers, 1)
  assert_true(bm.contains_range(5U, 9U))
  assert_true(bm.contains_range(100U, 103U))
  // Spanning the gap between the two runs is not covered.
  assert_false(bm.contains_range(5U, 103U))
  assert_false(bm.contains_range(8U, 101U))
}

///|
test "contains_range on a bitmap container checks bit-level coverage" {
  // Even numbers 0..16382: scattered (not consecutive, so this stays a
  // Bitmap rather than collapsing to a cheaper Run).
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  // A single value is trivially a "range" of length 1.
  assert_true(bm.contains_range(100U, 101U))
  // Odd numbers are absent, so a 2-wide range starting on an even value
  // (which includes the following odd value) is not fully covered.
  assert_false(bm.contains_range(100U, 102U))
}

///|
test "contains_range false when bucket is missing" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U])
  assert_false(bm.contains_range(70000U, 70010U))
}

///|
test "contains_range spans multiple buckets" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(60000U, 131201U)
  assert_true(bm.contains_range(60000U, 131201U))
  assert_false(bm.contains_range(59999U, 131201U))
}

///|
test "contains_range with start >= end is trivially true" {
  let bm = @moonbit-roaring.RoaringBitmap::new()
  assert_true(bm.contains_range(5U, 5U))
  assert_true(bm.contains_range(5U, 0U))
}

// ============ from_range ============

///|
test "from_range constructs the same bitmap as new + add_range" {
  let a = @moonbit-roaring.RoaringBitmap::from_range(100U, 200U)
  let b = @moonbit-roaring.RoaringBitmap::new().add_range(100U, 200U)
  assert_true(a.equals(b))
}

// ============ flip: complement within a closed interval ============

///|
test "flip complements a sparse bitmap inside the interval" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([10U, 11U, 12U, 20U])
  // [10, 12] is present, so those three drop out; [13, 19] was absent, so
  // it comes in; 20 sits outside the interval and is left alone.
  let flipped = bm.flip(10U, 19U)
  assert_eq(flipped.to_array(), [13U, 14U, 15U, 16U, 17U, 18U, 19U, 20U])
}

///|
test "flip of an empty bitmap is the whole interval" {
  let flipped = @moonbit-roaring.RoaringBitmap::new().flip(5U, 9U)
  assert_eq(flipped.to_array(), [5U, 6U, 7U, 8U, 9U])
  assert_eq(flipped.size(), 5)
}

///|
test "flip is an involution" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([3U, 4U, 100U, 101U])
  let once = bm.flip(0U, 200U)
  let twice = once.flip(0U, 200U)
  assert_eq(twice.to_array(), bm.to_array())
}

///|
test "flip leaves values outside the interval untouched" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 500U, 501U])
  let flipped = bm.flip(100U, 200U)
  assert_true(flipped.contains(1U))
  assert_true(flipped.contains(2U))
  assert_true(flipped.contains(500U))
  assert_true(flipped.contains(501U))
  // The interval was empty before, so all 101 of its values arrive.
  assert_true(flipped.contains(150U))
  assert_eq(flipped.size(), 4 + 101)
}

///|
test "flip size equals what lies outside plus the interval's complement" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(1000U, 2000U)
  let flipped = bm.flip(1500U, 2500U)
  // [1500, 2500] holds 1001 values, 500 of them already present. Those 500
  // drop out, the other 501 come in, and the 500 values below the interval
  // are carried over untouched.
  assert_eq(flipped.size(), 500 + 501)
  assert_eq(flipped.and_cardinality(bm), 500)
  assert_true(flipped.contains(1499U))
  assert_false(flipped.contains(1500U))
  assert_false(flipped.contains(1999U))
  assert_true(flipped.contains(2000U))
  assert_true(flipped.contains(2500U))
}

///|
test "flip over a whole bucket empties that bucket" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 65536U)
  assert_eq(bm.get_stats().total_containers, 1)
  let flipped = bm.flip(0U, 65535U)
  assert_true(flipped.is_empty())
  assert_eq(flipped.get_stats().total_containers, 0)
}

///|
test "flip over a partially filled bucket keeps the gaps" {
  // Complementing a bucket over its full range is "everything the bucket did
  // not already hold" — not "nothing". Only a completely full bucket flips
  // to empty, so these two cases must not collapse into one shortcut.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([0U, 65535U])
  let flipped = bm.flip(0U, 65535U)
  assert_eq(flipped.size(), 65534)
  assert_false(flipped.contains(0U))
  assert_false(flipped.contains(65535U))
  assert_true(flipped.contains(1U))
  assert_true(flipped.contains(65534U))
  // Flipping again restores the original exactly.
  assert_eq(flipped.flip(0U, 65535U).to_array(), bm.to_array())
}

///|
test "flip across a bucket boundary complements each side locally" {
  // Bucket 0 holds [0, 65535], bucket 1 holds [65536, 131071]. Flipping
  // [65530, 65540] must treat the two halves independently.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([65535U, 65536U])
  let flipped = bm.flip(65530U, 65540U)
  // 65535 and 65536 were present and are gone; 65530..65534 and 65537..65540
  // were absent and arrive.
  assert_false(flipped.contains(65535U))
  assert_false(flipped.contains(65536U))
  assert_true(flipped.contains(65530U))
  assert_true(flipped.contains(65540U))
  assert_eq(flipped.size(), 11 - 2)
}

///|
test "flip spanning many buckets complements each bucket locally" {
  // [0, 300000] covers buckets 0 through 4. Every bucket that already holds
  // data is complemented in place; every empty one is created from scratch.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([
    0U, 65535U, 65536U, 131071U, 299999U, 300000U,
  ])
  let flipped = bm.flip(0U, 300000U)
  assert_eq(flipped.size(), 300001 - 6)
  for v in [0U, 65535U, 65536U, 131071U, 299999U, 300000U] {
    assert_false(flipped.contains(v))
  }
  assert_true(flipped.contains(1U))
  assert_true(flipped.contains(65534U))
  assert_true(flipped.contains(150000U))
  // Values past the interval are untouched.
  assert_false(flipped.contains(300001U))
  // Round-trips through the portable format.
  let restored = match
    @moonbit-roaring.RoaringBitmap::deserialize(flipped.serialize()) {
    Ok(b) => b
    Err(_) => fail("multi-bucket flip must serialize and parse back")
  }
  assert_eq(restored.to_array(), flipped.to_array())
}

///|
test "flip with an inverted interval leaves the bitmap alone" {
  // Swapped bounds are a no-op, not an empty result: returning an empty
  // bitmap would silently discard every value. This matches CRoaring and
  // this package's own add_range/remove_range.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  assert_eq(bm.flip(10U, 5U).to_array(), bm.to_array())
  assert_eq(bm.flip(3U, 1U).to_array(), bm.to_array())
  // A closed interval of one value is not inverted: it toggles that value.
  assert_eq(bm.flip(1U, 1U).to_array(), [2U, 3U])
}

///|
test "flip of a single value toggles exactly that value" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([7U])
  assert_true(bm.flip(7U, 7U).is_empty())
  let absent = @moonbit-roaring.RoaringBitmap::from_array([8U])
  assert_eq(absent.flip(7U, 7U).to_array(), [7U, 8U])
}

// ============ add_range / remove_range as a single merge walk ============
//
// Both operations assemble the result container list in one pass, so they are
// linear in the buckets touched rather than rebuilding the list per bucket.
// These tests pin that against the operations they are defined in terms of.

///|
fn range_lcg(seed : Int32) -> Int32 {
  let raw = seed * 1103515245 + 12345
  if raw < 0 {
    -raw % 1000000
  } else {
    raw % 1000000
  }
}

///|
test "add_range equals union with the interval, on randomized inputs" {
  let mut seed = 31
  for _trial = 0; _trial < 40; _trial = _trial + 1 {
    seed = range_lcg(seed)
    let count = 1 + seed % 120
    let base = []
    for _i = 0; _i < count; _i = _i + 1 {
      seed = range_lcg(seed)
      base.push((seed % 400000).reinterpret_as_uint())
    }
    seed = range_lcg(seed)
    let a = (seed % 400000).reinterpret_as_uint()
    seed = range_lcg(seed)
    let b = (seed % 400000).reinterpret_as_uint()
    let lo = if a < b { a } else { b }
    let hi = if a < b { b } else { a }
    let start = @moonbit-roaring.RoaringBitmap::from_array(base)
    let via_range = start.add_range(lo, hi)
    let via_union = start.union(
      @moonbit-roaring.RoaringBitmap::from_range(lo, hi),
    )
    assert_eq(via_range.to_array(), via_union.to_array())
    assert_eq(via_range.serialize(), via_union.serialize())
  }
}

///|
test "remove_range equals difference with the interval, on randomized inputs" {
  let mut seed = 77
  for _trial = 0; _trial < 40; _trial = _trial + 1 {
    seed = range_lcg(seed)
    let count = 1 + seed % 120
    let base = []
    for _i = 0; _i < count; _i = _i + 1 {
      seed = range_lcg(seed)
      base.push((seed % 400000).reinterpret_as_uint())
    }
    seed = range_lcg(seed)
    let a = (seed % 400000).reinterpret_as_uint()
    seed = range_lcg(seed)
    let b = (seed % 400000).reinterpret_as_uint()
    let lo = if a < b { a } else { b }
    let hi = if a < b { b } else { a }
    let start = @moonbit-roaring.RoaringBitmap::from_array(base)
    let via_range = start.remove_range(lo, hi)
    let via_diff = start.difference(
      @moonbit-roaring.RoaringBitmap::from_range(lo, hi),
    )
    assert_eq(via_range.to_array(), via_diff.to_array())
    assert_eq(via_range.serialize(), via_diff.serialize())
  }
}

///|
test "add_range then remove_range round-trips on a disjoint interval" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([
    5U, 100U, 70000U, 200000U,
  ])
  let grown = bm.add_range(300000U, 400000U)
  assert_eq(grown.remove_range(300000U, 400000U).to_array(), bm.to_array())
  // An overlapping interval removes the original values inside it too, and
  // leaves the ones outside it alone.
  let overlapping = bm.add_range(1000U, 300000U)
  assert_eq(overlapping.remove_range(1000U, 300000U).to_array(), [5U, 100U])
}

///|
test "remove_range drops a fully covered bucket" {
  // The end is exclusive, so 131072 needs 131073 to be included.
  let one = @moonbit-roaring.RoaringBitmap::from_array([1U, 65536U, 131072U])
  assert_eq(one.remove_range(65536U, 131073U).to_array(), [1U])
  assert_eq(one.remove_range(0U, 131073U).to_array(), [])
  assert_true(one.remove_range(0U, 131073U).is_empty())
  // Removing a range that matches no bucket leaves the bitmap alone.
  assert_eq(one.remove_range(900000U, 900100U).to_array(), one.to_array())
}

///|
test "the whole 32-bit space is one add_range call" {
  let all = @moonbit-roaring.RoaringBitmap::new()
    .add_range(0U, 4294967295U)
    .add(4294967295U)
  assert_eq(all.get_stats().total_containers, 65536)
  assert_true(all.contains(0U))
  assert_true(all.contains(4294967295U))
  assert_eq(all.min(), Some(0U))
  assert_eq(all.max(), Some(4294967295U))
}

// ============ flip as a differential property ============
//
// `flip(start, end)` is defined as the complement within the closed interval,
// which is exactly the symmetric difference with that interval. Stating it
// that way gives a reference implementation to test against that shares no
// code with the one under test, so the word-level gap scanning added later
// can be verified without trusting it.

///|
/// `flip` over a closed interval equals xor with that interval. The two sides
/// share no code: one walks buckets and computes gaps, the other builds the
/// interval and runs the generic container xor.
fn assert_flip_matches_xor(
  bm : @moonbit-roaring.RoaringBitmap,
  start : UInt32,
  end : UInt32,
) -> Unit raise {
  // `from_range` is half-open, so the interval is [start, end + 1). That
  // addition wraps when `end` is UInt's maximum, so the top of the range is
  // built by adding the final value explicitly instead.
  let interval = if end == 4294967295U {
    @moonbit-roaring.RoaringBitmap::new()
    .add_range(start, 4294967295U)
    .add(4294967295U)
  } else {
    @moonbit-roaring.RoaringBitmap::from_range(start, end + 1U)
  }
  assert_eq(bm.flip(start, end).to_array(), bm.xor(interval).to_array())
  assert_eq(bm.flip(start, end).serialize(), bm.xor(interval).serialize())
}

///|
test "flip equals xor with the interval on randomized inputs" {
  let mut seed = 5150
  for _trial = 0; _trial < 50; _trial = _trial + 1 {
    seed = range_lcg(seed)
    let count = 1 + seed % 120
    let values = []
    for _i = 0; _i < count; _i = _i + 1 {
      seed = range_lcg(seed)
      values.push((seed % 400000).reinterpret_as_uint())
    }
    let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
    seed = range_lcg(seed)
    let a = (seed % 400000).reinterpret_as_uint()
    seed = range_lcg(seed)
    let b = (seed % 400000).reinterpret_as_uint()
    assert_flip_matches_xor(bm, a, b)
  }
}

///|
test "flip equals xor with the interval at bucket boundaries" {
  // Intervals that straddle bucket edges, cover whole buckets, and reach the
  // top of the 32-bit space, against each container representation.
  let sparse = @moonbit-roaring.RoaringBitmap::from_array([1U, 65535U, 65536U])
  let runs = @moonbit-roaring.RoaringBitmap::from_range(0U, 200000U)
  let dense_values = Array::makei(9000, i => (i * 7).reinterpret_as_uint())
  let dense = @moonbit-roaring.RoaringBitmap::from_array(dense_values)
  let intervals = [
    (0U, 0U),
    (65534U, 65537U),
    (65535U, 65536U),
    (0U, 65535U),
    (65536U, 131071U),
    (0U, 131072U),
    (4294967290U, 4294967295U),
    (4294967295U, 4294967295U),
  ]
  for bm in [sparse, runs, dense] {
    for (lo, hi) in intervals {
      assert_flip_matches_xor(bm, lo, hi)
    }
  }
}

///|
test "range_cardinality agrees with counting the materialized window" {
  let mut seed = 6161
  for _trial = 0; _trial < 40; _trial = _trial + 1 {
    seed = range_lcg(seed)
    let count = 1 + seed % 120
    let values = []
    for _i = 0; _i < count; _i = _i + 1 {
      seed = range_lcg(seed)
      values.push((seed % 400000).reinterpret_as_uint())
    }
    let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
    seed = range_lcg(seed)
    let a = (seed % 400000).reinterpret_as_uint()
    seed = range_lcg(seed)
    let b = (seed % 400000).reinterpret_as_uint()
    let lo = if a < b { a } else { b }
    let hi = if a < b { b } else { a }
    let expected = bm.range(lo, hi).size()
    assert_eq(bm.range_cardinality(lo, hi), expected)
    // An empty window is zero, not an error.
    assert_eq(bm.range_cardinality(hi, lo), 0L)
  }
}

///|
test "range_cardinality spans bucket boundaries" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 200000U)
  assert_eq(bm.range_cardinality(0U, 200000U), 200000L)
  assert_eq(bm.range_cardinality(65530U, 65540U), 10L)
  assert_eq(bm.range_cardinality(65536U, 65536U), 0L)
  assert_eq(bm.range_cardinality(199999U, 200000U), 1L)
  assert_eq(bm.range_cardinality(200000U, 300000U), 0L)
  assert_eq(bm.range_cardinality(0U, 0U), 0L)
}
