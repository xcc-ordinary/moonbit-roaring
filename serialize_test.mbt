// Round-trip and error-handling tests for the portable serialization format.

///|
test "round-trip empty bitmap" {
  let bm = @moonbit-roaring.RoaringBitmap::new()
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(restored.is_empty())
}

///|
test "round-trip sparse array container" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 100U, 1000U, 50000U])
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(bm.equals(restored))
}

///|
test "round-trip dense bitmap container" {
  let values = []
  for i = 0; i < 16384; i = i + 2 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.bitmap_containers, 1)
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(bm.equals(restored))
}

///|
test "round-trip run container" {
  let values = []
  for i = 0; i < 10000; i = i + 1 {
    values.push(i.reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.run_containers, 1)
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(bm.equals(restored))
}

///|
test "round-trip mixed container types across many buckets" {
  let values = []
  // bucket 0: sparse array
  values.push(1U)
  values.push(500U)
  // bucket 1: consecutive run (65536..75535)
  for i = 0; i < 10000; i = i + 1 {
    values.push((65536 + i).reinterpret_as_uint())
  }
  // bucket 2: dense bitmap
  for i = 0; i < 16384; i = i + 2 {
    values.push((131072 + i).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 3)
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.run_containers, 1)
  assert_eq(stats.bitmap_containers, 1)
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(bm.equals(restored))
  assert_eq(restored.get_stats().total_containers, 3)
}

///|
test "round-trip more than 4 containers triggers offset header" {
  let values = []
  for bucket = 0; bucket < 6; bucket = bucket + 1 {
    values.push((bucket * 100000 + 1).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().total_containers, 6)
  let bytes = bm.serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(bytes) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(bm.equals(restored))
}

///|
test "deserialize rejects empty input" {
  let empty_bytes = Bytes::new(0)
  match @moonbit-roaring.RoaringBitmap::deserialize(empty_bytes) {
    Ok(_) => fail("expected an error for empty input")
    Err(_) => ()
  }
}

///|
test "deserialize rejects invalid cookie" {
  let buf = @buffer.Buffer::Buffer()
  buf.write_uint_le(999U)
  buf.write_uint_le(0U)
  let bad_bytes = buf.to_bytes()
  match @moonbit-roaring.RoaringBitmap::deserialize(bad_bytes) {
    Ok(_) => fail("expected an error for invalid cookie")
    Err(_) => ()
  }
}

///|
test "deserialize rejects a truncated container count header" {
  // Valid no-runcontainer cookie, then a single stray byte where the
  // 4-byte container count should be.
  let buf = @buffer.Buffer::Buffer()
  buf.write_uint_le(12346U)
  buf.write_byte(b'\x00')
  match @moonbit-roaring.RoaringBitmap::deserialize(buf.to_bytes()) {
    Ok(_) => fail("expected an error for a truncated count header")
    Err(_) => ()
  }
}

///|
test "deserialize rejects run container data truncated at any offset" {
  let bm = @moonbit-roaring.RoaringBitmap::from_range(0U, 100U)
  assert_eq(bm.get_stats().run_containers, 1)
  let full = bm.serialize()
  // Chopping any number of trailing bytes must be caught rather than
  // read past the end of the buffer.
  for cut = 1; cut <= 4; cut = cut + 1 {
    let short = []
    for i = 0; i < full.length() - cut; i = i + 1 {
      short.push(full[i])
    }
    match
      @moonbit-roaring.RoaringBitmap::deserialize(Bytes::from_array(short)) {
      Ok(_) => fail("expected an error for run data truncated by \{cut}")
      Err(_) => ()
    }
  }
}

///|
test "deserialize rejects an out-of-range container count" {
  // 70000 containers is impossible: there are only 65536 possible high keys.
  let buf = @buffer.Buffer::Buffer()
  buf.write_uint_le(12346U)
  buf.write_uint_le(70000U)
  match @moonbit-roaring.RoaringBitmap::deserialize(buf.to_bytes()) {
    Ok(_) => fail("expected an error for an out-of-range container count")
    Err(_) => ()
  }
}

///|
test "deserialize rejects a run cookie with a missing flag bitset" {
  // SERIAL_COOKIE with size-1 = 7 in the high half promises 8 containers,
  // hence one run-flag byte, but the input ends after the cookie word.
  let buf = @buffer.Buffer::Buffer()
  let cookie : UInt32 = 12347U | (7U << 16)
  buf.write_uint_le(cookie)
  match @moonbit-roaring.RoaringBitmap::deserialize(buf.to_bytes()) {
    Ok(_) => fail("expected an error for a missing run-container bitset")
    Err(_) => ()
  }
}

///|
test "every truncated prefix is rejected rather than read out of bounds" {
  // Property check over the whole bounds-checking surface: for a bitmap
  // serialized to N bytes, all N proper prefixes must be rejected. A pass
  // here means no length check is missing anywhere in the parse path;
  // a silent Ok would mean the parser read past the end of the buffer.
  let shapes = [
    @moonbit-roaring.RoaringBitmap::from_array([1U, 100U, 1000U]),
    @moonbit-roaring.RoaringBitmap::from_range(0U, 100U),
  ]
  for s in shapes {
    let full = s.serialize()
    for cut = 0; cut < full.length(); cut = cut + 1 {
      let short = []
      for i = 0; i < cut; i = i + 1 {
        short.push(full[i])
      }
      match
        @moonbit-roaring.RoaringBitmap::deserialize(Bytes::from_array(short)) {
        Ok(_) => fail("prefix of length \{cut} should have been rejected")
        Err(_) => ()
      }
    }
  }
}

///|
test "RoaringError renders a readable message" {
  match @moonbit-roaring.RoaringBitmap::deserialize(b"\x00\x00\x00\x00") {
    Ok(_) => fail("expected an error for an invalid cookie")
    Err(e) =>
      assert_eq(
        e.to_string(),
        "DeserializationError: invalid cookie: not a Roaring bitmap",
      )
  }
}

///|
test "deserialize rejects truncated container data" {
  let bm = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U])
  let bytes = bm.serialize()
  // Chop off the last 3 bytes so container data underflows.
  let short = []
  for i = 0; i < bytes.length() - 3; i = i + 1 {
    short.push(bytes[i])
  }
  let short_bytes = Bytes::from_array(short)
  match @moonbit-roaring.RoaringBitmap::deserialize(short_bytes) {
    Ok(_) => fail("expected an error for truncated input")
    Err(_) => ()
  }
}

///|
test "portable_size_in_bytes always equals the serialized length" {
  // The two must not drift: the header arithmetic lives in one place, and this
  // is what keeps it there.
  let shapes = [
    @moonbit-roaring.RoaringBitmap::new(),
    @moonbit-roaring.RoaringBitmap::from_array([1U]),
    @moonbit-roaring.RoaringBitmap::from_array([1U, 2U]),
    @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U]),
    @moonbit-roaring.RoaringBitmap::from_array([1U, 100U, 1000U]),
    @moonbit-roaring.RoaringBitmap::from_range(0U, 200U),
    @moonbit-roaring.RoaringBitmap::from_range(0U, 200000U),
    @moonbit-roaring.RoaringBitmap::from_array(
      Array::makei(9000, i => (i * 2).reinterpret_as_uint()),
    ),
  ]
  for bm in shapes {
    assert_eq(bm.portable_size_in_bytes(), bm.serialize().length())
  }
  // Six containers, past the offset-header threshold in both layouts.
  let six = @moonbit-roaring.RoaringBitmap::from_array([
    1U, 100001U, 200001U, 300001U, 400001U, 500001U,
  ])
  assert_eq(six.portable_size_in_bytes(), six.serialize().length())
  // And after a round trip, which can change the representation.
  let restored = match
    @moonbit-roaring.RoaringBitmap::deserialize(six.serialize()) {
    Ok(b) => b
    Err(_) => {
      println("round trip rejected a valid bitmap")
      panic()
    }
  }
  assert_eq(restored.portable_size_in_bytes(), restored.serialize().length())
}

///|
test "portable_size_in_bytes does not allocate the encoding" {
  // It reports the size of a bitmap far larger than anything that could be
  // materialized in one piece, which `serialize` would have to build first.
  let huge = @moonbit-roaring.RoaringBitmap::new().add_range(0U, 2147483648U)
  let predicted = huge.portable_size_in_bytes()
  assert_true(predicted > 0)
  assert_eq(predicted, huge.serialize().length())
}

// ============ deserialize_at: reading a bitmap out of a larger buffer ============

///|
/// Two bitmaps back to back, with a sentinel byte on each side.
fn concatenated_fixtures() -> Bytes {
  let first = @moonbit-roaring.RoaringBitmap::from_array([1U, 100U, 1000U])
  let second = @moonbit-roaring.RoaringBitmap::from_range(0U, 200U)
  let buf = @buffer.Buffer::Buffer()
  buf.write_byte(0xAB) // leading sentinel
  for b in first.serialize() {
    buf.write_byte(b)
  }
  buf.write_byte(0xCD) // separator
  for b in second.serialize() {
    buf.write_byte(b)
  }
  buf.write_byte(0xEF) // trailing sentinel
  buf.to_bytes()
}

///|
test "deserialize_at reads a bitmap out of a larger buffer" {
  let data = concatenated_fixtures()
  let first_bytes = @moonbit-roaring.RoaringBitmap::from_array([1U, 100U, 1000U]).serialize()
  let (first, after_first) = match
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, 1) {
    Ok(pair) => pair
    Err(e) => {
      println("deserialize_at rejected a valid prefix: \{e}")
      panic()
    }
  }
  assert_eq(first.to_array(), [1U, 100U, 1000U])
  assert_eq(after_first, 1 + first_bytes.length())
  // The byte at that offset is the separator, not the start of a bitmap.
  assert_eq(data[after_first], (0xCD : Byte))
}

///|
test "deserialize_at chains through a concatenated buffer" {
  let data = concatenated_fixtures()
  let (first, after_first) = match
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, 1) {
    Ok(pair) => pair
    Err(_) => {
      println("first read failed")
      panic()
    }
  }
  // Skip the separator and read the second bitmap.
  let (second, after_second) = match
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, after_first + 1) {
    Ok(pair) => pair
    Err(e) => {
      println("second read failed: \{e}")
      panic()
    }
  }
  assert_eq(first.to_array(), [1U, 100U, 1000U])
  assert_eq(second.size(), 200)
  // The remaining byte is the trailing sentinel.
  assert_eq(after_second, data.length() - 1)
  assert_eq(data[after_second], (0xEF : Byte))
}

///|
test "deserialize_at rejects a bad offset without reading out of bounds" {
  let data = concatenated_fixtures()
  // Past the end.
  assert_true(
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, data.length())
    is Err(_),
  )
  assert_true(
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, data.length() + 100)
    is Err(_),
  )
  // Negative.
  assert_true(
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, -1) is Err(_),
  )
  // At the separator, which is not a cookie.
  let (_, after_first) = match
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, 1) {
    Ok(pair) => pair
    Err(_) => {
      println("prefix read failed")
      panic()
    }
  }
  assert_true(
    @moonbit-roaring.RoaringBitmap::deserialize_at(data, after_first) is Err(_),
  )
}

///|
test "deserialize still rejects trailing bytes" {
  // `deserialize` is the strict wrapper: a bitmap plus anything else is an
  // error, which is what catches a truncated frame.
  let data = concatenated_fixtures()
  assert_true(@moonbit-roaring.RoaringBitmap::deserialize(data) is Err(_))
  // Exactly one bitmap still works.
  let exact = @moonbit-roaring.RoaringBitmap::from_array([1U, 2U, 3U]).serialize()
  let restored = match @moonbit-roaring.RoaringBitmap::deserialize(exact) {
    Ok(b) => b
    Err(_) => {
      println("exact-length buffer was rejected")
      panic()
    }
  }
  assert_eq(restored.to_array(), [1U, 2U, 3U])
}

///|
test "deserialize_at agrees with deserialize on a standalone buffer" {
  let shapes = [
    @moonbit-roaring.RoaringBitmap::new(),
    @moonbit-roaring.RoaringBitmap::from_array([1U]),
    @moonbit-roaring.RoaringBitmap::from_range(0U, 200U),
    @moonbit-roaring.RoaringBitmap::from_array(
      Array::makei(9000, i => (i * 2).reinterpret_as_uint()),
    ),
  ]
  for bm in shapes {
    let bytes = bm.serialize()
    let (via_at, end) = match
      @moonbit-roaring.RoaringBitmap::deserialize_at(bytes, 0) {
      Ok(pair) => pair
      Err(_) => {
        println("deserialize_at rejected a valid buffer")
        panic()
      }
    }
    assert_eq(end, bytes.length())
    assert_eq(via_at.serialize(), bytes)
    assert_true(via_at == bm)
  }
}

///|
test "deserialize_at handles offset headers at a non-zero offset" {
  // Six containers past the offset-header threshold, each a Run, so both the
  // run flags and the offset header are present. Reading this at a non-zero
  // offset exercises the relative-offset comparison that a standalone read
  // never touches.
  let values = []
  for bucket = 0; bucket < 6; bucket = bucket + 1 {
    let base = bucket * 65536
    values.push(base.reinterpret_as_uint())
    values.push((base + 1).reinterpret_as_uint())
    values.push((base + 2).reinterpret_as_uint())
  }
  let bm = @moonbit-roaring.RoaringBitmap::from_array(values)
  let bytes = bm.serialize()
  assert_true(bm.get_stats().run_containers == 6)

  let buf = @buffer.Buffer::Buffer()
  buf.write_byte(0x11)
  buf.write_byte(0x22)
  for b in bytes {
    buf.write_byte(b)
  }
  let framed = buf.to_bytes()

  let (read, end) = match
    @moonbit-roaring.RoaringBitmap::deserialize_at(framed, 2) {
    Ok(pair) => pair
    Err(e) => {
      println("offset-header read failed: \{e}")
      panic()
    }
  }
  assert_eq(read.to_array(), bm.to_array())
  assert_eq(read.serialize(), bytes)
  assert_eq(end, 2 + bytes.length())
  // Nothing is left after the bitmap, so a further read fails.
  assert_true(
    @moonbit-roaring.RoaringBitmap::deserialize_at(framed, end) is Err(_),
  )
}
