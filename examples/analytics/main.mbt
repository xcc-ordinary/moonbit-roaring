// Bitmap-level analytics without expanding the whole set: cumulative count
// with rank and percentile-like lookup with select.
//
// Run with: moon run examples/analytics

///|
fn main {
  let matched_ids = @roaring.RoaringBitmap::from_array([
    10U, 20U, 30U, 100U, 200U, 500U,
  ])
  let count_at_or_below_100 = matched_ids.rank(100U)
  let fourth_match = matched_ids.select(3).unwrap()

  println("matches at or below ID 100: \{count_at_or_below_100}")
  println("fourth smallest match: \{fourth_match}")
}
