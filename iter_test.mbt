// Tests for the lazy iter() and the rank()/select() query pair.

// ============ iter() ============

///|
test "iter over an empty bitmap yields nothing" {
  let bm = RoaringBitmap::new()
  assert_eq(bm.iter().to_array(), [])
}

///|
test "iter yields elements in ascending order within one bucket" {
  let bm = RoaringBitmap::from_array([50U, 10U, 30U, 10U])
  assert_eq(bm.iter().to_array(), [10U, 30U, 50U])
}

///|
test "iter yields elements across multiple buckets in ascending order" {
  let bm = RoaringBitmap::from_array([200000U, 1U, 70000U])
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
  let bm = RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.run_containers, 1)
  assert_eq(stats.bitmap_containers, 1)
  assert_eq(bm.iter().to_array(), bm.to_array())
}

///|
test "iter supports early termination via take" {
  let bm = RoaringBitmap::from_range(0U, 1000U)
  assert_eq(bm.iter().take(3).to_array(), [0U, 1U, 2U])
}

///|
test "iter supports find_first" {
  let bm = RoaringBitmap::from_array([5U, 15U, 25U, 35U])
  assert_eq(bm.iter().find_first(x => x > 20U), Some(25U))
  assert_eq(bm.iter().find_first(x => x > 100U), None)
}

// ============ rank() ============

///|
test "rank on empty bitmap is always zero" {
  let bm = RoaringBitmap::new()
  assert_eq(bm.rank(0U), 0)
  assert_eq(bm.rank(4294967295U), 0)
}

///|
test "rank counts elements less than or equal to value" {
  let bm = RoaringBitmap::from_array([10U, 20U, 30U])
  assert_eq(bm.rank(5U), 0)
  assert_eq(bm.rank(10U), 1)
  assert_eq(bm.rank(15U), 1)
  assert_eq(bm.rank(20U), 2)
  assert_eq(bm.rank(30U), 3)
  assert_eq(bm.rank(1000U), 3)
}

///|
test "rank of the maximum element equals size" {
  let bm = RoaringBitmap::from_array([7U, 42U, 999U])
  assert_eq(bm.rank(bm.max().unwrap()), bm.size())
}

///|
test "rank spans multiple buckets correctly" {
  let bm = RoaringBitmap::from_array([1U, 70000U, 140000U])
  assert_eq(bm.rank(1U), 1)
  assert_eq(bm.rank(69999U), 1)
  assert_eq(bm.rank(70000U), 2)
  assert_eq(bm.rank(139999U), 2)
  assert_eq(bm.rank(140000U), 3)
}

///|
test "rank on a run container matches array semantics" {
  let bm = RoaringBitmap::from_range(100U, 200U)
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
  let bm = RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  assert_eq(bm.rank(0U), 1)
  assert_eq(bm.rank(1U), 1) // 1 is absent; rank counts <= 1, only 0 qualifies
  assert_eq(bm.rank(9998U), 5000)
}

// ============ select() ============

///|
test "select on empty bitmap is always None" {
  let bm = RoaringBitmap::new()
  assert_eq(bm.select(0), None)
}

///|
test "select rejects negative and out-of-range indices" {
  let bm = RoaringBitmap::from_array([1U, 2U, 3U])
  assert_eq(bm.select(-1), None)
  assert_eq(bm.select(3), None)
  assert_eq(bm.select(100), None)
}

///|
test "select returns the index-th smallest element" {
  let bm = RoaringBitmap::from_array([30U, 10U, 20U])
  assert_eq(bm.select(0), Some(10U))
  assert_eq(bm.select(1), Some(20U))
  assert_eq(bm.select(2), Some(30U))
}

///|
test "select spans multiple buckets correctly" {
  let bm = RoaringBitmap::from_array([1U, 70000U, 140000U])
  assert_eq(bm.select(0), Some(1U))
  assert_eq(bm.select(1), Some(70000U))
  assert_eq(bm.select(2), Some(140000U))
}

///|
test "select on a run container matches array semantics" {
  let bm = RoaringBitmap::from_range(100U, 200U)
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
  let bm = RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().bitmap_containers, 1)
  assert_eq(bm.select(0), Some(0U))
  assert_eq(bm.select(1), Some(2U))
  assert_eq(bm.select(8191), Some(16382U))
}

///|
test "rank and select are inverse operations for present elements" {
  let bm = RoaringBitmap::from_array([5U, 70000U, 70050U, 200000U])
  for v in bm.to_array() {
    let r = bm.rank(v)
    assert_eq(bm.select(r - 1), Some(v))
  }
}
