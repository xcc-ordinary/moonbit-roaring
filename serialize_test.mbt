// Round-trip and error-handling tests for the portable serialization format.

///|
test "round-trip empty bitmap" {
  let bm = RoaringBitmap::new()
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(restored.is_empty())
}

///|
test "round-trip sparse array container" {
  let bm = RoaringBitmap::from_array([1U, 100U, 1000U, 50000U])
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
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
  let bm = RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.bitmap_containers, 1)
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
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
  let bm = RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.run_containers, 1)
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
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
  let bm = RoaringBitmap::from_array(values)
  let stats = bm.get_stats()
  assert_eq(stats.total_containers, 3)
  assert_eq(stats.array_containers, 1)
  assert_eq(stats.run_containers, 1)
  assert_eq(stats.bitmap_containers, 1)
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
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
  let bm = RoaringBitmap::from_array(values)
  assert_eq(bm.get_stats().total_containers, 6)
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(bm.equals(restored))
}

///|
test "deserialize rejects empty input" {
  let empty_bytes = Bytes::new(0)
  match RoaringBitmap::deserialize(empty_bytes, true) {
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
  match RoaringBitmap::deserialize(bad_bytes, true) {
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
  match RoaringBitmap::deserialize(buf.to_bytes(), true) {
    Ok(_) => fail("expected an error for a truncated count header")
    Err(_) => ()
  }
}

///|
test "deserialize rejects run container data truncated at any offset" {
  let bm = RoaringBitmap::from_range(0U, 100U)
  assert_eq(bm.get_stats().run_containers, 1)
  let full = bm.serialize(true)
  // Chopping any number of trailing bytes must be caught rather than
  // read past the end of the buffer.
  for cut = 1; cut <= 4; cut = cut + 1 {
    let short = []
    for i = 0; i < full.length() - cut; i = i + 1 {
      short.push(full[i])
    }
    match RoaringBitmap::deserialize(Bytes::from_array(short), true) {
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
  match RoaringBitmap::deserialize(buf.to_bytes(), true) {
    Ok(_) => fail("expected an error for an out-of-range container count")
    Err(_) => ()
  }
}

///|
test "deserialize rejects a run cookie with a missing flag bitset" {
  // SERIAL_COOKIE with size-1 = 7 in the high half promises 8 containers,
  // hence one run-flag byte, but the input ends after the cookie word.
  let buf = @buffer.Buffer::Buffer()
  let cookie : UInt = 12347U | (7U << 16)
  buf.write_uint_le(cookie)
  match RoaringBitmap::deserialize(buf.to_bytes(), true) {
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
    RoaringBitmap::from_array([1U, 100U, 1000U]),
    RoaringBitmap::from_range(0U, 100U),
  ]
  for s in shapes {
    let full = s.serialize(true)
    for cut = 0; cut < full.length(); cut = cut + 1 {
      let short = []
      for i = 0; i < cut; i = i + 1 {
        short.push(full[i])
      }
      match RoaringBitmap::deserialize(Bytes::from_array(short), true) {
        Ok(_) => fail("prefix of length \{cut} should have been rejected")
        Err(_) => ()
      }
    }
  }
}

///|
test "RoaringError renders a readable message" {
  match RoaringBitmap::deserialize(b"\x00\x00\x00\x00", true) {
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
  let bm = RoaringBitmap::from_array([1U, 2U, 3U])
  let bytes = bm.serialize(true)
  // Chop off the last 3 bytes so container data underflows.
  let short = []
  for i = 0; i < bytes.length() - 3; i = i + 1 {
    short.push(bytes[i])
  }
  let short_bytes = Bytes::from_array(short)
  match RoaringBitmap::deserialize(short_bytes, true) {
    Ok(_) => fail("expected an error for truncated input")
    Err(_) => ()
  }
}
