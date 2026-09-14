// Round-trip and error-handling tests for the portable serialization format.

test "round-trip empty bitmap" {
  let bm = RoaringBitmap::new()
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(restored.is_empty())
}

test "round-trip sparse array container" {
  let bm = RoaringBitmap::from_array([1U, 100U, 1000U, 50000U])
  let bytes = bm.serialize(true)
  let restored = match RoaringBitmap::deserialize(bytes, true) {
    Ok(r) => r
    Err(_) => fail("expected successful deserialize")
  }
  assert_true(bm.equals(restored))
}

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

test "deserialize rejects empty input" {
  let empty_bytes = Bytes::new(0)
  match RoaringBitmap::deserialize(empty_bytes, true) {
    Ok(_) => fail("expected an error for empty input")
    Err(_) => ()
  }
}

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

test "deserialize rejects truncated container data" {
  let bm = RoaringBitmap::from_array([1U, 2U, 3U])
  let bytes = bm.serialize(true)
  // Chop off the last 3 bytes so container data underflows.
  let truncated = bytes.to_unchecked_string(offset=0, length=bytes.length() - 3)
  ignore(truncated)
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
