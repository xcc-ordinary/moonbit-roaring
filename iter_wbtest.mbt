// Whitebox tests for the lazy iteration cursor: for every container
// representation and seek point it must produce exactly the suffix of the
// decoded bucket, combined with the bucket key. The decode pipeline
// (container_to_sorted_array) is the reference the lazy path has to match
// value for value.

///|
fn cursor_drain(cursor : LazyCursor) -> Array[UInt32] {
  let out : Array[UInt32] = []
  let mut more = true
  while more {
    match cursor.next() {
      Some(v) => out.push(v)
      None => more = false
    }
  }
  out
}

///|
fn assert_cursor_matches_decode(key : UInt16, c : Container) -> Unit raise {
  let decoded = container_to_sorted_array(c)
  // A fresh cursor drains the whole container.
  let expected_full : Array[UInt32] = []
  for v in decoded {
    expected_full.push(combine(key, v))
  }
  assert_eq(cursor_drain(LazyCursor::new(key, c)), expected_full)
  // Seek points: fixed word/bucket boundaries, sampled present values, and
  // the gap just below each sampled value. Sampling keeps the check cheap
  // even for dense containers.
  let probes : Array[UInt16] = [0, 1, 63, 64, 65, 32767, 32768, 65534, 65535]
  let stride = if decoded.length() > 16 { decoded.length() / 16 } else { 1 }
  for i = 0; i < decoded.length(); i = i + stride {
    probes.push(decoded[i])
    if decoded[i] > 0 {
      probes.push(decoded[i] - 1)
    }
  }
  for p in probes {
    let expected : Array[UInt32] = []
    for v in decoded {
      if v >= p {
        expected.push(combine(key, v))
      }
    }
    let cursor = LazyCursor::new(key, c)
    cursor.seek(p)
    assert_eq(cursor_drain(cursor), expected)
  }
}

///|
test "lazy cursor matches decode on Array containers" {
  assert_cursor_matches_decode(0, Array([]))
  assert_cursor_matches_decode(0, Array([3, 100, 4095, 65535]))
  // A non-zero key pins the high/low combination.
  assert_cursor_matches_decode(7, Array([3, 100, 4095, 65535]))
}

///|
test "lazy cursor matches decode on Bitmap containers" {
  // Evens across all 1024 words: 32768 values, the realistic dense shape.
  assert_cursor_matches_decode(
    0,
    Bitmap(FixedArray::make(1024, 0x5555555555555555UL)),
  )
  // A single full word among empty ones: exercises zero-word skipping and
  // seeks into the middle of the only populated word.
  let one_word = FixedArray::make(1024, 0UL)
  one_word[512] = 0xFFFFFFFFFFFFFFFFUL
  assert_cursor_matches_decode(0, Bitmap(one_word))
  // Empty bitmap container.
  assert_cursor_matches_decode(0, Bitmap(FixedArray::make(1024, 0UL)))
}

///|
test "lazy cursor matches decode on Run containers" {
  assert_cursor_matches_decode(0, Run([]))
  assert_cursor_matches_decode(0, Run([Run::{ start: 5, length: 0, }]))
  assert_cursor_matches_decode(
    3,
    Run([
      Run::{ start: 0, length: 9999, },
      Run::{ start: 20000, length: 2, },
      Run::{ start: 65530, length: 5, },
    ]),
  )
}
