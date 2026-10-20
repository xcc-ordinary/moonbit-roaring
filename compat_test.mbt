// Compatibility-oriented convenience APIs that make migration from
// kesmeey/RoaringBitmap explicit and testable at the public bitmap boundary.

///|
test "clear returns an empty bitmap without changing the original" {
  let original = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 65536U])
  let cleared = original.clear()
  assert_true(cleared.is_empty())
  assert_eq(original.to_array(), [1U, 2U, 65536U])
}

///|
test "jaccard_similarity uses intersection over union" {
  let a = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let b = @moonbit-roaring.RoaringBitmap::from_array([2U, 3U, 4U])
  assert_eq(a.jaccard_similarity(b), 0.5)
  assert_eq(
    @moonbit-roaring.RoaringBitmap::new().jaccard_similarity(
      @moonbit-roaring.RoaringBitmap::new(),
    ),
    1.0,
  )
}

///|
test "range keeps existing values inside inclusive bounds" {
  let bitmap = @moonbit-roaring.RoaringBitmap::from_array([
    1U, 5U, 10U, 15U, 20U, 65536U,
  ])
  assert_eq(bitmap.range(5U, 15U).to_array(), [5U, 10U, 15U])
  // An inverted interval is a no-op, like add_range, remove_range, flip and
  // contains_range. Returning an empty bitmap here would silently discard
  // every value on swapped bounds.
  assert_eq(bitmap.range(20U, 19U).to_array(), bitmap.to_array())
  assert_eq(bitmap.range(65536U, 65536U).to_array(), [65536U])
}
