// Regression tests for the 32-bit `Int` cardinality ceiling.
//
// A bitmap can hold up to 2^32 values, which does not fit in MoonBit's 32-bit
// signed `Int`. Several methods used to turn "cannot count" into a wrong
// answer rather than an honest failure: `is_empty` reported a full universe as
// empty, `select` reported every index as out of range on a provably
// non-empty bitmap, and `rank` reported a negative count.
//
// The fixture is built by writing portable bytes directly instead of calling
// `add_range`, which is quadratic in the number of buckets touched and would
// take the better part of a minute to lay down 32768 containers.

///|
/// 32768 buckets, each holding all 65536 of its values as a single Run:
/// exactly 2^31 elements, the point where a 32-bit signed `Int` wraps.
fn overflowing_bitmap() -> @moonbit-roaring.RoaringBitmap {
  let buckets = 32768
  let buf = @buffer.Buffer::Buffer()
  // SERIAL_COOKIE layout: low 16 bits are the cookie, high 16 bits are
  // (container count - 1).
  buf.write_uint_le(12347U | ((buckets - 1).reinterpret_as_uint() << 16))
  // One run-flag byte per 8 containers, all set: every container is a Run.
  for _i = 0; _i < (buckets + 7) / 8; _i = _i + 1 {
    buf.write_byte(0xFF)
  }
  // Descriptive header: (key, cardinality - 1) per container.
  for k = 0; k < buckets; k = k + 1 {
    buf.write_uint16_le(k.to_uint16())
    buf.write_uint16_le((65535 : UInt16))
  }
  // Offset header: with runs present it is written once the count reaches 4.
  let mut offset = 4 + 8 * buckets + (buckets + 7) / 8
  for _k = 0; _k < buckets; _k = _k + 1 {
    buf.write_uint_le(offset.reinterpret_as_uint())
    offset = offset + 6
  }
  // Container data: a single run covering the whole bucket, 6 bytes each.
  for _k = 0; _k < buckets; _k = _k + 1 {
    buf.write_uint16_le((1 : UInt16))
    buf.write_uint16_le((0 : UInt16))
    buf.write_uint16_le((65535 : UInt16))
  }
  match @moonbit-roaring.RoaringBitmap::deserialize(buf.to_bytes()) {
    Ok(b) => b
    Err(e) => {
      // `panic` takes no message on this toolchain, so print first.
      println("fixture rejected by the decoder: \{e}")
      panic()
    }
  }
}

///|
test "the overflowing fixture decodes to 32768 full Run containers" {
  let bm = overflowing_bitmap()
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 32768)
  assert_eq(stats.run_containers, 32768)
  assert_eq(stats.array_containers, 0)
  assert_eq(stats.bitmap_containers, 0)
  // Re-serializing reproduces the exact bytes the decoder accepted:
  // cookie + run flags + descriptive header + offset header + container data.
  // The descriptive header is 4 bytes per container (key + cardinality), and
  // the offset header another 4.
  assert_eq(
    bm.serialize().length(),
    4 + 4096 + 4 * 32768 + 4 * 32768 + 6 * 32768,
  )
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
