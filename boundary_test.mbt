// Boundary and cost-tie-break tests.
//
// optimize_container() picks the cheapest of three encodings by comparing
// byte cost directly (Array: n*2, Bitmap: fixed 8192, Run: runs*4). These
// tests pin down the exact tie-break points, since "which one wins when
// costs are equal" is exactly the kind of detail that's easy to get wrong
// silently.

// ============ Array vs Bitmap tie-break (both cost 8192 bytes at n=4096) ============

///|
test "exactly 4096 scattered values ties Array vs Bitmap, Array wins" {
  // Each value is isolated (no two consecutive), so Run costs far more
  // than either. At n=4096, array_cost == bitmap_cost == 8192; the tie
  // should resolve to Array (array_cost <= bitmap_cost is checked first).
  let values = []
  for i = 0; i < 4096; i = i + 1 {
    values.push((i * 2).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.size(), 4096)
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.bitmap_containers, 0)
}

///|
test "4097 scattered values breaks the tie toward Bitmap" {
  let values = []
  for i = 0; i < 4097; i = i + 1 {
    values.push((i * 2).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.size(), 4097)
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 0)
  assert_eq(stats.bitmap_containers, 1)
}

// ============ Run vs Array cost comparison ============
//
// The cost model has to agree with what serialization actually writes, which
// for a Run container is a two-byte run count followed by four bytes per run.
// CRoaring makes the same comparison — verified against `roaring-wasm`, whose
// `runOptimize` picks Array for two consecutive values and Run for three.

///|
test "two consecutive values are cheaper as an Array than a Run" {
  // One run [5,6] costs 2 + 4 = 6 bytes on the wire; as an array, two
  // elements cost 4. Array wins, matching CRoaring.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([5U, 6U])
  let stats = bm.get_stats()
  assert_eq(stats.run_containers, 0)
  assert_eq(stats.array_containers, 1)
  // cookie + count + descriptive header + offset header + 2 array values
  assert_eq(bm.serialize().length(), 4 + 4 + 4 + 4 + 4)
}

///|
test "three consecutive values tie and the tie goes to Run" {
  // One run [5,7] costs 2 + 4 = 6 bytes; three array elements also cost 6.
  // The tie resolves to Run, again matching CRoaring.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([5U, 6U, 7U])
  let stats = bm.get_stats()
  assert_eq(stats.run_containers, 1)
  assert_eq(stats.array_containers, 0)
  // cookie + run flags + descriptive header + (no offsets: one container is
  // below the threshold) + run count + one run
  assert_eq(bm.serialize().length(), 4 + 1 + 4 + 2 + 4)
}

///|
test "a single isolated value never becomes a Run" {
  // One run of length 0 costs 4 bytes; as an array, 1 element costs 2
  // bytes. Array must win: a lone value should never pay the Run overhead.
  let bm = @moonbit-roaring.RoaringBitmap::singleton(42U)
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.run_containers, 0)
}

///|
test "three consecutive values prefer Run over Array" {
  // One run costs 4 bytes; as an array, 3 elements cost 6 bytes.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([10U, 11U, 12U])
  let stats = bm.get_stats()
  assert_eq(stats.run_containers, 1)
}

// ============ UInt16 / UInt32 boundary values ============

///|
test "value 0 is stored and retrieved correctly" {
  let bm = @moonbit-roaring.RoaringBitmap::singleton(0U)
  assert_true(bm.contains(0U))
  assert_eq(bm.to_array(), [0U])
}

///|
test "max low-16 value 65535 stays in bucket 0" {
  let bm = @moonbit-roaring.RoaringBitmap::singleton(65535U)
  assert_true(bm.contains(65535U))
  assert_eq(bm.get_stats().total_containers, 1)
}

///|
test "min high-16 value 65536 starts bucket 1" {
  let bm = @moonbit-roaring.RoaringBitmap::singleton(65536U)
  assert_true(bm.contains(65536U))
  assert_false(bm.contains(65535U))
}

///|
test "0 and UInt32 max coexist without collision" {
  let min_val = 0U
  let max_val = 4294967295U // 2^32 - 1
  let bm = @moonbit-roaring.RoaringBitmap::from_array([min_val, max_val])
  assert_eq(bm.size(), 2)
  assert_true(bm.contains(min_val))
  assert_true(bm.contains(max_val))
  assert_eq(bm.min(), Some(min_val))
  assert_eq(bm.max(), Some(max_val))
}

///|
test "values straddling a mid-range bucket boundary" {
  // 2^31 sits exactly on a high-16 boundary (bucket 32768).
  let boundary : UInt = 2147483648U // 2^31
  let bm = @moonbit-roaring.RoaringBitmap::from_array([boundary - 1, boundary])
  assert_eq(bm.size(), 2)
  assert_true(bm.contains(boundary - 1))
  assert_true(bm.contains(boundary))
  assert_eq(bm.get_stats().total_containers, 2)
}

// ============ Downgrade paths ============

///|
test "removing elements downgrades Bitmap back to Array" {
  let values = []
  for i = 0; i < 4097; i = i + 1 {
    values.push((i * 2).reinterpret_as_uint())
  }
  let mut bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  // Remove enough scattered values to make Array cheaper again.
  for i = 0; i < 4090; i = i + 1 {
    bm = bm.remove((i * 2).reinterpret_as_uint())
  }
  assert_eq(bm.size(), 7)
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.bitmap_containers, 0)
}

///|
test "removing the only element of a container drops the container entirely" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 70000U]).remove(
    70000U,
  )
  assert_eq(bm.size(), 1)
  assert_eq(bm.get_stats().total_containers, 1)
  assert_false(bm.contains(70000U))
}

// ============ Many buckets: run-flag bitset spans multiple bytes ============

///|
test "run flag bitset correctly marks a bit past the first byte" {
  // 10 buckets: buckets 0-8 hold a single sparse value each (Array,
  // cheapest for 1 element); bucket 9 holds a consecutive run. Container
  // index 9 falls in the second run-flag byte (byte_idx=1, bit=1), which
  // exercises the multi-byte bitset path in both serialize and deserialize.
  let values = []
  for bucket = 0; bucket < 9; bucket = bucket + 1 {
    values.push((bucket * 100000 + 1).reinterpret_as_uint())
  }
  for i = 0; i < 20; i = i + 1 {
    values.push((9 * 100000 + i).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 10)
  assert_eq(stats.array_containers, 9)
  assert_eq(stats.run_containers, 1)
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(restored.equals(bm))
  assert_eq(restored.get_stats().run_containers, 1)
}

// ============ add_many across boundaries ============

///|
test "add_many with duplicates spanning multiple buckets deduplicates correctly" {
  let values = [1U, 1U, 70000U, 70000U, 1U, 140000U]
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.size(), 3)
  assert_eq(bm.to_array(), [1U, 70000U, 140000U])
}

///|
test "add_many then scattered remove leaves correct residual set" {
  let values = []
  for i = 0; i < 100; i = i + 1 {
    values.push(i.reinterpret_as_uint())
  }
  let mut bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  for i = 0; i < 100; i = i + 2 {
    bm = bm.remove(i.reinterpret_as_uint())
  }
  assert_eq(bm.size(), 50)
  for i = 1; i < 100; i = i + 2 {
    assert_true(bm.contains(i.reinterpret_as_uint()))
  }
  for i = 0; i < 100; i = i + 2 {
    assert_false(bm.contains(i.reinterpret_as_uint()))
  }
}
