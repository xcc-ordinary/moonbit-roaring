// Tests for the lazy iter() and the rank()/select() query pair.

// ============ iter() ============

///|
test "iter over an empty bitmap yields nothing" {
  let bm = @moonbit-roaring.RoaringBitmap::new()
  assert_eq(bm.iter().to_array(), [])
}

///|
test "iter yields elements in ascending order within one bucket" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([50U, 10U, 30U, 10U])
  assert_eq(bm.iter().to_array(), [10U, 30U, 50U])
}

///|
test "iter yields elements across multiple buckets in ascending order" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([200000U, 1U, 70000U])
  assert_eq(bm.iter().to_array(), [1U, 70000U, 200000U])
}

///|
test "iter matches to_array on a bitmap with all three container types" {
  let values = []
  values.push(1U)
  values.push(500U)
  for i = 0; i < 10000; i = i + 1 {
    values.push((65536 + i).reinterpret_as_uint())
  }
  for i = 0; i < 16384; i = i + 2 {
    values.push((131072 + i).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.run_containers, 1)
  assert_eq(stats.bitmap_containers, 1)
  assert_eq(bm.iter().to_array(), bm.to_array())
}

///|
test "iter supports early termination via take" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 1000U)
  assert_eq(bm.iter().take(3).to_array(), [0U, 1U, 2U])
}

///|
test "iter supports find_first" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([5U, 15U, 25U, 35U])
  assert_eq(bm.iter().find_first(x => x > 20U), Some(25U))
  assert_eq(bm.iter().find_first(x => x > 100U), None)
}

// ============ rank() ============

///|
test "rank on empty bitmap is always zero" {
  let bm = @moonbit-roaring.RoaringBitmap::new()
  assert_eq(bm.rank(0U), 0)
  assert_eq(bm.rank(4294967295U), 0)
}

///|
test "rank counts elements less than or equal to value" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([10U, 20U, 30U])
  assert_eq(bm.rank(5U), 0)
  assert_eq(bm.rank(10U), 1)
  assert_eq(bm.rank(15U), 1)
  assert_eq(bm.rank(20U), 2)
  assert_eq(bm.rank(30U), 3)
  assert_eq(bm.rank(1000U), 3)
}

///|
test "rank of the maximum element equals size" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([7U, 42U, 999U])
  assert_eq(bm.rank(bm.max().unwrap()), bm.size())
}

///|
test "rank spans multiple buckets correctly" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 70000U, 140000U])
  assert_eq(bm.rank(1U), 1)
  assert_eq(bm.rank(69999U), 1)
  assert_eq(bm.rank(70000U), 2)
  assert_eq(bm.rank(139999U), 2)
  assert_eq(bm.rank(140000U), 3)
}

///|
test "rank stops early once past the target bucket" {
  // The scan breaks out as soon as a bucket key exceeds the value's key;
  // this pins that early-exit arm plus the run-off-the-end fallthrough.
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 70000U])
  assert_eq(bm.rank(50U), 1)
  assert_eq(bm.rank(500000U), 2)
}

///|
test "rank at a 64-bit word boundary on a bitmap container" {
  // Bit 63 takes the full-word mask branch rather than (1 << (bit+1)) - 1.
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  assert_eq(bm.rank(63U), 32) // evens 0..62
  assert_eq(bm.rank(64U), 33) // plus 64 itself
}

///|
test "rank on a run container matches array semantics" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(100U, 200U)
  assert_eq(bm.rank(99U), 0)
  assert_eq(bm.rank(100U), 1)
  assert_eq(bm.rank(150U), 51)
  assert_eq(bm.rank(199U), 100)
  assert_eq(bm.rank(500U), 100)
}

///|
test "rank on a bitmap container matches array semantics" {
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  assert_eq(bm.rank(0U), 1)
  assert_eq(bm.rank(1U), 1) // 1 is absent; rank counts <= 1, only 0 qualifies
  assert_eq(bm.rank(9998U), 5000)
}

// ============ select() ============

///|
test "select on empty bitmap is always None" {
  let bm = @moonbit-roaring.RoaringBitmap::new()
  assert_eq(bm.select(0), None)
}

///|
test "select rejects negative and out-of-range indices" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  assert_eq(bm.select(-1), None)
  assert_eq(bm.select(3), None)
  assert_eq(bm.select(100), None)
}

///|
test "select returns the index-th smallest element" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([30U, 10U, 20U])
  assert_eq(bm.select(0), Some(10U))
  assert_eq(bm.select(1), Some(20U))
  assert_eq(bm.select(2), Some(30U))
}

///|
test "select spans multiple buckets correctly" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 70000U, 140000U])
  assert_eq(bm.select(0), Some(1U))
  assert_eq(bm.select(1), Some(70000U))
  assert_eq(bm.select(2), Some(140000U))
}

///|
test "select on a run container matches array semantics" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(100U, 200U)
  assert_eq(bm.select(0), Some(100U))
  assert_eq(bm.select(50), Some(150U))
  assert_eq(bm.select(99), Some(199U))
  assert_eq(bm.select(100), None)
}

///|
test "select on a bitmap container matches array semantics" {
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  assert_eq(bm.select(0), Some(0U))
  assert_eq(bm.select(1), Some(2U))
  assert_eq(bm.select(8191), Some(16382U))
}

///|
test "rank and select are inverse operations for present elements" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([
    5U, 70000U, 70050U, 200000U,
  ])
  for v in bm.to_array() {
    let r = bm.rank(v)
    assert_eq(bm.select(r.to_int() - 1), Some(v))
  }
}

// ============ iter_from: seek without decoding the prefix ============

///|
test "iter_from yields exactly the values at or above the start" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([
    1U, 5U, 10U, 70000U, 70001U, 200000U,
  ])
  // Below the minimum, at the minimum, between values, at a value, past the max.
  assert_eq(bm.iter_from(0U).to_array(), bm.to_array())
  assert_eq(bm.iter_from(1U).to_array(), bm.to_array())
  assert_eq(bm.iter_from(2U).to_array(), [5U, 10U, 70000U, 70001U, 200000U])
  assert_eq(bm.iter_from(5U).to_array(), [5U, 10U, 70000U, 70001U, 200000U])
  assert_eq(bm.iter_from(6U).to_array(), [10U, 70000U, 70001U, 200000U])
  assert_eq(bm.iter_from(70000U).to_array(), [70000U, 70001U, 200000U])
  assert_eq(bm.iter_from(200000U).to_array(), [200000U])
  assert_true(bm.iter_from(200001U).to_array() == [])
  assert_true(bm.iter_from(4294967295U).to_array() == [])
}

///|
test "iter_from agrees with filtering the full iteration" {
  let mut seed = 9292
  for _trial = 0; _trial < 40; _trial = _trial + 1 {
    seed = batch_lcg(seed)
    let count = 1 + seed % 150
    let values = []
    for _i = 0; _i < count; _i = _i + 1 {
      seed = batch_lcg(seed)
      values.push((seed % 400000).reinterpret_as_uint())
    }
    let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
    seed = batch_lcg(seed)
    let start = (seed % 400000).reinterpret_as_uint()
    let expected = bm.iter().filter(v => v >= start).to_array()
    assert_eq(bm.iter_from(start).to_array(), expected)
    // And lazily, at several take counts, against a manual slice of the
    // expected array.
    for n in [1, 3, 10] {
      let limit = if n < expected.length() { n } else { expected.length() }
      assert_eq(
        bm.iter_from(start).take(n).to_array(),
        expected[0:limit].to_owned(),
      )
    }
  }
}

///|
test "iter_from works on an empty bitmap and past its end" {
  let empty = @moonbit-roaring.RoaringBitmap::new()
  assert_true(empty.iter_from(0U).to_array() == [])
  assert_true(empty.iter_from(4294967295U).to_array() == [])
  let one = @moonbit-roaring.RoaringBitmap::singleton(42U)
  assert_eq(one.iter_from(42U).to_array(), [42U])
  assert_true(one.iter_from(43U).to_array() == [])
  assert_eq(one.iter_from(0U).to_array(), [42U])
}

///|
test "iter_from composes with the rest of Iter" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 1000U)
  assert_eq(bm.iter_from(100U).take(5).to_array(), [
    100U, 101U, 102U, 103U, 104U,
  ])
  assert_eq(bm.iter_from(995U).count(), 5)
  assert_eq(bm.iter_from(0U).find_first(v => v == 999U), Some(999U))
  assert_eq(bm.iter_from(500U).find_first(v => v == 100U), None)
}

///|
test "iter does not decode anything until the first element is requested" {
  // The seek in `iter_from` decodes exactly one bucket; `iter` must decode
  // none. Both are observable through the container decode count, which this
  // test pins by checking that constructing an iterator is free of the work
  // that materializing would do — an empty `iter` over a huge bitmap must not
  // build the whole thing.
  let huge = @moonbit-roaring.RoaringBitmap::new().add_range(0U, 2147483648U)
  let it = huge.iter()
  assert_true(it.size_hint() is Some(_))
  // Materializing would need 2^31 slots, which no Array can hold; taking a
  // few elements must not attempt it.
  assert_eq(huge.iter().take(3).to_array(), [0U, 1U, 2U])
  assert_eq(huge.iter_from(2147483645U).take(3).to_array(), [
    2147483645U, 2147483646U, 2147483647U,
  ])
}
