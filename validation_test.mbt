// Semantic validation at the public portable-deserialization boundary.

///|
fn expect_deserialize_error(data : Bytes) -> Unit {
  match RoaringBitmap::deserialize(data) {
    Ok(_) => abort("expected malformed portable bitmap to be rejected")
    Err(_) => ()
  }
}

///|
test "deserialize rejects non-increasing container keys" {
  expect_deserialize_error(
    b"\x3a\x30\x00\x00\x02\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x18\x00\x00\x00\x1a\x00\x00\x00\x00\x00\x00\x00",
  )
}

///|
test "deserialize rejects unsorted array-container values" {
  expect_deserialize_error(
    b"\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x01\x00\x10\x00\x00\x00\x02\x00\x01\x00",
  )
}

///|
test "deserialize rejects an invalid container offset" {
  expect_deserialize_error(
    b"\x3a\x30\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00",
  )
}

///|
test "deserialize rejects overlapping run-container entries" {
  expect_deserialize_error(
    b"\x3b\x30\x00\x00\x01\x00\x03\x00\x02\x00\x00\x00\x02\x00\x02\x00\x00\x00",
  )
}

///|
test "deserialize rejects bitmap cardinality mismatch" {
  let data : Array[Byte] = [
    0x3a, 0x30, 0x00, 0x00, // no-run cookie
     0x01, 0x00, 0x00, 0x00, // one container
     0x00, 0x00, 0x00, 0x10, // key=0, declared cardinality=4097
     0x10, 0x00, 0x00, 0x00, // container offset=16
  ]
  for i = 0; i < 8192; i = i + 1 {
    data.push(0x00)
  }
  expect_deserialize_error(@buffer.from_array(data).to_bytes())
}

///|
test "deserialize rejects trailing bytes" {
  expect_deserialize_error(b"\x3a\x30\x00\x00\x00\x00\x00\x00\xff")
}
