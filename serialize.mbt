// CRoaring-compatible "portable" binary serialization.
// Byte layout follows https://github.com/RoaringBitmap/RoaringFormatSpec
// exactly: cookie header, descriptive header, optional offset header, then
// container data. All integers are little-endian.

///|
let serial_cookie_no_runcontainer : UInt = 12346U

///|
let serial_cookie : UInt = 12347U

///|
let no_offset_threshold : Int = 4

///|
fn has_run_container(containers : Array[HighContainer]) -> Bool {
  let mut found = false
  for hc in containers {
    match hc.container {
      Run(_) => found = true
      _ => ()
    }
  }
  found
}

///|
fn container_byte_size(c : Container) -> Int {
  match c {
    Array(arr) => arr.length() * 2
    Bitmap(_) => bitmap_container_size_bytes
    Run(runs) => 2 + 4 * runs.length()
  }
}

///|
/// One flag byte per 8 containers: bit i set means container i is a Run.
fn run_flag_bytes(containers : Array[HighContainer]) -> Array[Byte] {
  let n = containers.length()
  let nbytes = (n + 7) / 8
  let bytes = []
  for byte_idx = 0; byte_idx < nbytes; byte_idx = byte_idx + 1 {
    let mut b = 0
    for bit = 0; bit < 8; bit = bit + 1 {
      let i = byte_idx * 8 + bit
      if i < n {
        match containers[i].container {
          Run(_) => b = b.lor(1 << bit)
          _ => ()
        }
      }
    }
    bytes.push(b.to_byte())
  }
  bytes
}

///|
fn write_container_data(buf : @buffer.Buffer, c : Container) -> Unit {
  match c {
    Array(arr) =>
      for v in arr {
        buf.write_uint16_le(v)
      }
    Bitmap(words) =>
      for i = 0; i < words.length(); i = i + 1 {
        buf.write_uint64_le(words[i])
      }
    Run(runs) => {
      buf.write_uint16_le(runs.length().to_uint16())
      for r in runs {
        buf.write_uint16_le(r.start)
        buf.write_uint16_le(r.length)
      }
    }
  }
}

///|
/// Serialize to the CRoaring-compatible portable binary format.
/// The `portable` flag is accepted for API parity with CRoaring's
/// serialize(portable); only the portable/interoperable format is
/// implemented in this project (see README non-goals for the native/frozen
/// format, which is future work).
pub fn RoaringBitmap::serialize(self : RoaringBitmap, portable : Bool) -> Bytes {
  ignore(portable)
  let containers = self.containers
  let size = containers.length()
  let buf = @buffer.Buffer::Buffer()
  if !has_run_container(containers) {
    // SERIAL_COOKIE_NO_RUNCONTAINER layout: always used when there are no
    // run containers, matching CRoaring's isomorphism recommendation.
    buf.write_uint_le(serial_cookie_no_runcontainer)
    buf.write_uint_le(size.reinterpret_as_uint())
    for hc in containers {
      buf.write_uint16_le(hc.key)
      buf.write_uint16_le((hc.cardinality - 1).to_uint16())
    }
    // Offset header is always present in this layout.
    let mut offset = 8 + 8 * size
    for hc in containers {
      buf.write_uint_le(offset.reinterpret_as_uint())
      offset = offset + container_byte_size(hc.container)
    }
  } else {
    // SERIAL_COOKIE layout: low 16 bits = cookie, high 16 bits = size - 1.
    let cookie_word : UInt = serial_cookie |
      ((size - 1).reinterpret_as_uint() << 16)
    buf.write_uint_le(cookie_word)
    for b in run_flag_bytes(containers) {
      buf.write_byte(b)
    }
    for hc in containers {
      buf.write_uint16_le(hc.key)
      buf.write_uint16_le((hc.cardinality - 1).to_uint16())
    }
    if size >= no_offset_threshold {
      let run_flag_len = (size + 7) / 8
      let mut offset = 4 + 8 * size + run_flag_len
      for hc in containers {
        buf.write_uint_le(offset.reinterpret_as_uint())
        offset = offset + container_byte_size(hc.container)
      }
    }
  }
  for hc in containers {
    write_container_data(buf, hc.container)
  }
  buf.to_bytes()
}

// ============ Deserialization ============

///|
priv struct ParsedCookie {
  size : Int
  has_runs : Bool
  run_flags : Array[Byte]
  next_pos : Int
}

///|
fn check_len(data : Bytes, pos : Int, need : Int) -> Bool {
  pos >= 0 && need >= 0 && pos + need <= data.length()
}

///|
fn parse_cookie(data : Bytes) -> Result[ParsedCookie, RoaringError] {
  if !check_len(data, 0, 4) {
    return Err(DeserializationError("input too short for cookie header"))
  }
  let cookie_word = data.unsafe_read_uint32_le(0)
  let low16 = cookie_word % 65536U
  if low16 == serial_cookie_no_runcontainer {
    if !check_len(data, 4, 4) {
      return Err(DeserializationError("truncated: missing container count"))
    }
    let sz = data.unsafe_read_uint32_le(4).reinterpret_as_int()
    let parsed : ParsedCookie = {
      size: sz,
      has_runs: false,
      run_flags: [],
      next_pos: 8,
    }
    Ok(parsed)
  } else if low16 == serial_cookie {
    let sz = (cookie_word / 65536U).reinterpret_as_int() + 1
    let flag_len = (sz + 7) / 8
    if !check_len(data, 4, flag_len) {
      return Err(
        DeserializationError("truncated: missing run-container bitset"),
      )
    }
    let flags = []
    for i = 0; i < flag_len; i = i + 1 {
      flags.push(data.unsafe_get(4 + i))
    }
    let parsed : ParsedCookie = {
      size: sz,
      has_runs: true,
      run_flags: flags,
      next_pos: 4 + flag_len,
    }
    Ok(parsed)
  } else {
    Err(DeserializationError("invalid cookie: not a Roaring bitmap"))
  }
}

///|
fn is_run_flag_set(run_flags : Array[Byte], k : Int) -> Bool {
  let byte_idx = k / 8
  let bit = k % 8
  if byte_idx >= run_flags.length() {
    false
  } else {
    run_flags[byte_idx].to_int().land(1 << bit) != 0
  }
}

///|
fn read_array_container(
  data : Bytes,
  pos : Int,
  cardinality : Int,
) -> Array[UInt16] {
  let arr = []
  for i = 0; i < cardinality; i = i + 1 {
    arr.push(data.unsafe_read_uint16_le(pos + i * 2))
  }
  arr
}

///|
fn read_bitmap_container(data : Bytes, pos : Int) -> FixedArray[UInt64] {
  let words = FixedArray::make(1024, 0UL)
  for i = 0; i < 1024; i = i + 1 {
    words[i] = data.unsafe_read_uint64_le(pos + i * 8)
  }
  words
}

///|
/// Deserialize from the CRoaring-compatible portable binary format.
/// Rejects truncated or malformed input with a RoaringError rather than
/// reading out of bounds.
pub fn RoaringBitmap::deserialize(
  data : Bytes,
  portable : Bool,
) -> Result[RoaringBitmap, RoaringError] {
  ignore(portable)
  let parsed = match parse_cookie(data) {
    Ok(p) => p
    Err(e) => return Err(e)
  }
  let size = parsed.size
  let has_runs = parsed.has_runs
  let run_flags = parsed.run_flags
  if size < 0 || size > 65536 {
    return Err(DeserializationError("container count out of range"))
  }
  let mut pos = parsed.next_pos

  // Descriptive header: (key, cardinality) per container.
  if !check_len(data, pos, 4 * size) {
    return Err(DeserializationError("truncated: descriptive header"))
  }
  let keys : Array[UInt16] = []
  let cardinalities : Array[Int] = []
  for k = 0; k < size; k = k + 1 {
    let key = data.unsafe_read_uint16_le(pos)
    let card_minus1 = data.unsafe_read_uint16_le(pos + 2)
    keys.push(key)
    cardinalities.push(card_minus1.to_int() + 1)
    pos = pos + 4
  }

  // Offset header: present under the same rule used when writing.
  let has_offsets = !has_runs || size >= no_offset_threshold
  if has_offsets {
    if !check_len(data, pos, 4 * size) {
      return Err(DeserializationError("truncated: offset header"))
    }
    pos = pos + 4 * size
  }

  // Container data, in key order.
  let containers : Array[HighContainer] = []
  for k = 0; k < size; k = k + 1 {
    let cardinality = cardinalities[k]
    let is_run = has_runs && is_run_flag_set(run_flags, k)
    let container = if is_run {
      if !check_len(data, pos, 2) {
        return Err(DeserializationError("truncated: run container header"))
      }
      let n_runs = data.unsafe_read_uint16_le(pos).to_int()
      pos = pos + 2
      if !check_len(data, pos, 4 * n_runs) {
        return Err(DeserializationError("truncated: run container data"))
      }
      let runs : Array[Run] = []
      for i = 0; i < n_runs; i = i + 1 {
        let start = data.unsafe_read_uint16_le(pos)
        let length = data.unsafe_read_uint16_le(pos + 2)
        runs.push(Run::{ start, length, })
        pos = pos + 4
      }
      Run(runs)
    } else if cardinality <= array_container_max_size {
      if !check_len(data, pos, 2 * cardinality) {
        return Err(DeserializationError("truncated: array container data"))
      }
      let arr = read_array_container(data, pos, cardinality)
      pos = pos + 2 * cardinality
      Array(arr)
    } else {
      if !check_len(data, pos, bitmap_container_size_bytes) {
        return Err(DeserializationError("truncated: bitmap container data"))
      }
      let words = read_bitmap_container(data, pos)
      pos = pos + bitmap_container_size_bytes
      Bitmap(words)
    }
    containers.push(HighContainer::{
      key: keys[k],
      container,
      cardinality: container_cardinality(container),
    })
  }
  let total = rebuild_size(containers)
  Ok({ containers, size: total, })
}
