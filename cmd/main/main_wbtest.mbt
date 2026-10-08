// Whitebox tests for the CLI's text codecs. These are the only parts of
// cmd/main that are pure functions, and they sit directly on the trust
// boundary with whatever other tool produced the hex, so they get real
// coverage rather than being exercised only by hand.

///|
test "hex round trip" {
  let data = Bytes::from_array([0x00, 0x0f, 0x10, 0xa5, 0xff])
  assert_eq(to_hex(data), "000f10a5ff")
  assert_eq(parse_hex(to_hex(data)), Ok(data))
}

///|
test "parse_hex accepts a 0x prefix and surrounding whitespace" {
  let expected = Bytes::from_array([0x3a, 0x30, 0x00, 0x00])
  assert_eq(parse_hex("0x3a300000"), Ok(expected))
  assert_eq(parse_hex("3a 30 00 00"), Ok(expected))
  assert_eq(parse_hex("  3a30\n0000\t"), Ok(expected))
  assert_eq(parse_hex("0X3A300000"), Ok(expected))
}

///|
test "parse_hex rejects malformed input" {
  assert_true(parse_hex("abc") is Err(_))
  assert_true(parse_hex("zz") is Err(_))
  assert_true(parse_hex("") is Ok(b""))
}

///|
test "parse_uint accepts decimal and rejects the rest" {
  assert_eq(parse_uint("0"), Ok(0U))
  assert_eq(parse_uint("4294967295"), Ok(4294967295U))
  assert_true(parse_uint("") is Err(_))
  assert_true(parse_uint("12x") is Err(_))
  assert_true(parse_uint("-1") is Err(_))
  assert_true(parse_uint("1 000") is Err(_))
}

///|
test "encode then check agrees on a portable round trip" {
  // The two subcommands share the hex codec, so a bitmap built by `encode`
  // must be accepted by `check` as byte-for-byte identical.
  let bitmap = @roaring.RoaringBitmap::from_array([1U, 100U, 1000U])
  let hex = to_hex(bitmap.serialize())
  let decoded = match parse_hex(hex) {
    Ok(d) => d
    Err(e) => fail("hex codec lost bytes: \{e}")
  }
  assert_eq(decoded, bitmap.serialize())
}
