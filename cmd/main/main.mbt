// Command-line front end for the Roaring portable format.
//
// The library exists for interoperability, so the CLI speaks the one thing
// every Roaring implementation agrees on: the portable byte sequence. Bytes
// travel in and out as hex, which keeps the tool dependency-free and runnable
// on wasm, wasm-gc, js and native alike — no file I/O to configure, nothing to
// install beyond the MoonBit toolchain.

///|
fn hex_nibble(value : Int) -> Char {
  if value < 10 {
    (value + '0'.to_int()).unsafe_to_char()
  } else {
    (value - 10 + 'a'.to_int()).unsafe_to_char()
  }
}

///|
fn to_hex(data : Bytes) -> String {
  let chars = []
  for i = 0; i < data.length(); i = i + 1 {
    let byte = data[i].to_int()
    chars.push(hex_nibble(byte / 16))
    chars.push(hex_nibble(byte % 16))
  }
  String::from_array(chars)
}

///|
fn nibble_value(c : Char) -> Int? {
  if c >= '0' && c <= '9' {
    Some(c.to_int() - '0'.to_int())
  } else if c >= 'a' && c <= 'f' {
    Some(c.to_int() - 'a'.to_int() + 10)
  } else if c >= 'A' && c <= 'F' {
    Some(c.to_int() - 'A'.to_int() + 10)
  } else {
    None
  }
}

///|
/// Accepts an optional `0x`/`0X` prefix and any embedded whitespace, so bytes
/// can be pasted straight out of another tool's output.
fn parse_hex(text : String) -> Result[Bytes, String] {
  let chars = text.to_array()
  let mut start = 0
  if chars.length() >= 2 &&
    chars[0] == '0' &&
    (chars[1] == 'x' || chars[1] == 'X') {
    start = 2
  }
  let digits = []
  for i = start; i < chars.length(); i = i + 1 {
    let c = chars[i]
    if c.is_whitespace() {
      continue
    }
    match nibble_value(c) {
      Some(v) => digits.push(v)
      None => return Err("not a hex digit: \{c.escape()}")
    }
  }
  if digits.length() % 2 != 0 {
    return Err("hex input has an odd number of digits")
  }
  let bytes = []
  for i = 0; i < digits.length(); i = i + 2 {
    bytes.push((digits[i] * 16 + digits[i + 1]).to_byte())
  }
  Ok(Bytes::from_array(bytes))
}

///|
fn parse_uint(text : String) -> Result[UInt, String] {
  let chars = text.to_array()
  if chars.length() == 0 {
    return Err("empty number")
  }
  let max_value : UInt = 4294967295U
  let mut value : UInt = 0U
  for c in chars {
    if c < '0' || c > '9' {
      return Err("not a decimal number: \{text}")
    }
    let digit = (c.to_int() - '0'.to_int()).reinterpret_as_uint()
    // `UInt` is 32-bit and wraps silently, so a value past 4294967295 would
    // be quietly truncated into a different bitmap rather than rejected.
    if value > (max_value - digit) / 10U {
      return Err("number out of range (max 4294967295): \{text}")
    }
    value = value * 10U + digit
  }
  Ok(value)
}

///|
fn report(error : String) -> Unit {
  println("error: \{error}")
}

// ============ subcommands ============

///|
/// Decode portable bytes and describe what they hold: the values, the
/// container mix the decoder chose, and how the encoding compares to a naive
/// bitmap. This is the "what did the other language actually send me" view.
fn run_info(hex : String) -> Unit {
  let data = match parse_hex(hex) {
    Ok(d) => d
    Err(e) => {
      report(e)
      return
    }
  }
  let bitmap = match @roaring.RoaringBitmap::deserialize(data) {
    Ok(b) => b
    Err(e) => {
      report(e.to_string())
      return
    }
  }
  let stats = bitmap.get_stats()
  let min_text = match bitmap.min() {
    Some(v) => v.to_string()
    None => "-"
  }
  let max_text = match bitmap.max() {
    Some(v) => v.to_string()
    None => "-"
  }
  println("values          \{bitmap.size()}")
  println("min / max       \{min_text} / \{max_text}")
  println(
    "containers      \{stats.total_containers} (array \{stats.array_containers}, bitmap \{stats.bitmap_containers}, run \{stats.run_containers})",
  )
  println("container bytes \{stats.total_bytes_used}")
  println("serialized      \{data.length()}")
}

///|
/// Build a bitmap and print its portable bytes as hex — the inverse of `info`,
/// and the half of the interop story that produces data for another language
/// to read. Values come from the command line or from a `--start`/`--end`
/// half-open range.
fn run_encode(values : Array[String], start : String?, end : String?) -> Unit {
  let bitmap = match (start, end) {
    (Some(s), Some(e)) => {
      let lo = match parse_uint(s) {
        Ok(v) => v
        Err(msg) => {
          report(msg)
          return
        }
      }
      let hi = match parse_uint(e) {
        Ok(v) => v
        Err(msg) => {
          report(msg)
          return
        }
      }
      @roaring.RoaringBitmap::from_range(lo, hi)
    }
    (Some(_), None) | (None, Some(_)) => {
      report("--start and --end must be given together")
      return
    }
    (None, None) => {
      let parsed = []
      for text in values {
        match parse_uint(text) {
          Ok(v) => parsed.push(v)
          Err(msg) => {
            report(msg)
            return
          }
        }
      }
      @roaring.RoaringBitmap::from_array(parsed)
    }
  }
  println(to_hex(bitmap.serialize()))
}

///|
/// Verify a portable byte sequence survives a decode/encode round trip
/// unchanged, and that the bitmap's own query methods agree with each other.
/// A mismatch means either the input was not valid portable data or this
/// implementation disagreed with whoever produced it.
fn run_check(hex : String) -> Unit {
  let data = match parse_hex(hex) {
    Ok(d) => d
    Err(e) => {
      report(e)
      return
    }
  }
  let bitmap = match @roaring.RoaringBitmap::deserialize(data) {
    Ok(b) => b
    Err(e) => {
      report(e.to_string())
      return
    }
  }
  let reencoded = bitmap.serialize()
  if reencoded != data {
    report(
      "round trip is not byte-for-byte: \{data.length()} bytes in, \{reencoded.length()} out",
    )
    return
  }
  // Internal consistency: rank and select must agree with size, min and max.
  match bitmap.max() {
    None => ()
    Some(m) =>
      if bitmap.rank(m) != Int64::from_int(bitmap.size()) {
        report("rank(max) does not equal size")
        return
      }
  }
  if bitmap.size() > 0 {
    match bitmap.select(0) {
      None => {
        report("select(0) returned None for a non-empty bitmap")
        return
      }
      Some(first) =>
        if first != bitmap.min().unwrap() {
          report("select(0) does not equal min")
          return
        }
    }
  }
  println(
    "ok: \{bitmap.size()} values in \{data.length()} bytes, byte-for-byte round trip",
  )
}

// ============ entry point ============

///|
fn info_command() -> @argparse.Command {
  @argparse.Command(
    "info",
    about="Decode portable bytes and report their structure",
    positionals=[
      @argparse.PositionArg("hex", about="Portable bytes, hex encoded"),
    ],
  )
}

///|
fn encode_command() -> @argparse.Command {
  @argparse.Command(
    "encode",
    about="Build a bitmap and print its portable bytes as hex",
    positionals=[
      @argparse.PositionArg(
        "values",
        about="Decimal values",
        num_args=@argparse.ValueRange(lower=0),
      ),
    ],
    options=[
      @argparse.OptionArg(
        "start",
        about="Build a half-open range instead of a value list",
      ),
      @argparse.OptionArg("end", about="Exclusive upper bound of the range"),
    ],
  )
}

///|
fn check_command() -> @argparse.Command {
  @argparse.Command(
    "check",
    about="Verify a portable byte sequence round-trips exactly",
    positionals=[
      @argparse.PositionArg("hex", about="Portable bytes, hex encoded"),
    ],
  )
}

///|
fn main {
  let info = info_command()
  let encode = encode_command()
  let check = check_command()
  let cmd = @argparse.Command(
    "roaring",
    about="Inspect and produce Roaring portable bitmaps",
    subcommand_required=true,
    subcommands=[info, encode, check],
  )
  // argparse prints help and version text itself but reports real parse
  // errors by raising; print those rather than aborting, because `abort`
  // discards its message on non-native targets.
  let matches = cmd.parse() catch {
    err => {
      println(err.to_string())
      return
    }
  }
  let (name, child) = match matches.subcommand {
    Some(pair) => pair
    None => {
      // Unreachable while the root command requires a subcommand; print the
      // usage rather than exiting silently if that ever changes.
      println(cmd.render_help())
      return
    }
  }
  // A required positional that argparse somehow let through is a bug, not a
  // user error, so fall back to the subcommand's own help text.
  let hex_argument = fn() -> String? {
    match child.values.get("hex") {
      Some(args) => Some(args[0])
      None => None
    }
  }
  match name {
    "info" =>
      match hex_argument() {
        Some(hex) => run_info(hex)
        None => println(info.render_help())
      }
    "encode" => {
      let values = match child.values.get("values") {
        Some(v) => v
        None => []
      }
      let start = match child.values.get("start") {
        Some(v) => Some(v[0])
        None => None
      }
      let end = match child.values.get("end") {
        Some(v) => Some(v[0])
        None => None
      }
      run_encode(values, start, end)
    }
    "check" =>
      match hex_argument() {
        Some(hex) => run_check(hex)
        None => println(check.render_help())
      }
    _ => println("unknown subcommand: \{name}")
  }
}
