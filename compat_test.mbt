// Compatibility-oriented convenience APIs that make migration from
// kesmeey/RoaringBitmap explicit and testable at the public bitmap boundary.

///|
test "clear returns an empty bitmap without changing the original" {
  let original = RoaringBitmap::from_array([1U, 2U, 65536U])
  let cleared = original.clear()
  assert_true(cleared.is_empty())
  assert_eq(original.to_array(), [1U, 2U, 65536U])
}

///|
test "jaccard_similarity uses intersection over union" {
  let a = RoaringBitmap::from_array([1U, 2U, 3U])
  let b = RoaringBitmap::from_array([2U, 3U, 4U])
  assert_eq(a.jaccard_similarity(b), 0.5)
  assert_eq(RoaringBitmap::new().jaccard_similarity(RoaringBitmap::new()), 1.0)
}

///|
test "range keeps existing values inside inclusive bounds" {
  let bitmap = RoaringBitmap::from_array([1U, 5U, 10U, 15U, 20U, 65536U])
  assert_eq(bitmap.range(5U, 15U).to_array(), [5U, 10U, 15U])
  assert_true(bitmap.range(20U, 19U).is_empty())
  assert_eq(bitmap.range(65536U, 65536U).to_array(), [65536U])
}
