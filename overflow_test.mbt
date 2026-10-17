// Regression tests for the 32-bit `Int` cardinality ceiling.
//
// A bitmap can hold up to 2^32 values, which does not fit in MoonBit's 32-bit
// signed `Int`. Several methods used to turn "cannot count" into a wrong
// answer rather than an honest failure: `is_empty` reported a full universe as
// empty, `select` reported every index as out of range on a provably
// non-empty bitmap, and `rank` reported a negative count.
//
// The fixture is built with a single `add_range` call. It used to be
// assembled by writing portable bytes by hand, because `add_range` was
// quadratic in the number of buckets touched and took the better part of a
// minute to lay down 32768 containers; it now takes milliseconds.

///|
/// 32768 buckets, each holding all 65536 of its values as a single Run:
/// exactly 2^31 elements, the point where a 32-bit signed `Int` wraps.
fn overflowing_bitmap() -> @moonbit-roaring.RoaringBitmap {
  @moonbit-roaring.RoaringBitmap::new().add_range(0U, 2147483648U)
}

///|
test "the overflowing fixture is 32768 full Run containers" {
  let bm = overflowing_bitmap()
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 32768)
  assert_eq(stats.run_containers, 32768)
  assert_eq(stats.array_containers, 0)
  assert_eq(stats.bitmap_containers, 0)
}

///|
test "the overflowing fixture survives a portable round trip" {
  // Also covers the decoder at a container count far past anything the other
  // fixtures reach.
  let bm = overflowing_bitmap()
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(b) => b
    Err(_) => {
      println("2^31-element bitmap was rejected by the decoder")
      panic()
    }
  }
  assert_eq(restored.get_stats().total_containers, 32768)
  assert_eq(restored.serialize(), bytes)
  assert_true(restored.contains(0U))
  assert_true(restored.contains(2147483647U))
  assert_eq(restored.min(), Some(0U))
}

///|
test "is_empty is false past the Int cardinality range" {
  let bm = overflowing_bitmap()
  assert_false(bm.is_empty())
  assert_true(bm.contains(0U))
  assert_true(bm.contains(2147483647U))
  assert_eq(bm.min(), Some(0U))
  // size() itself wraps; that is the documented 32-bit Int limitation, and it
  // is why is_empty no longer derives its answer from it.
  assert_eq(bm.size(), -2147483648)
}

///|
test "select works past the Int cardinality range" {
  let bm = overflowing_bitmap()
  assert_eq(bm.select(0), Some(0U))
  assert_eq(bm.select(1), Some(1U))
  assert_eq(bm.select(65535), Some(65535U))
  assert_eq(bm.select(65536), Some(65536U))
  assert_eq(bm.select(2147483647), Some(2147483647U))
}

///|
test "rank stays exact past the Int cardinality range" {
  let bm = overflowing_bitmap()
  assert_eq(bm.rank(0U), 1L)
  assert_eq(bm.rank(65535U), 65536L)
  assert_eq(bm.rank(65536U), 65537L)
  // 2^31, which no 32-bit signed Int can hold.
  assert_eq(bm.rank(2147483647U), 2147483648L)
}

///|
test "rank and select stay inverse past the Int cardinality range" {
  let bm = overflowing_bitmap()
  for v in [0U, 1U, 65535U, 65536U, 2147483647U] {
    assert_true(bm.contains(v))
    assert_eq(bm.select(bm.rank(v).to_int() - 1), Some(v))
  }
}
