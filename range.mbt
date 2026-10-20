// Range operations: add/remove/query a half-open [start, end) run of values
// in one call, instead of forcing callers to materialize every value first.
//
// Design: split the incoming [start, end) range by high-16-bit bucket key.
// For a bucket fully covered by the range, `add_range` writes a single Run
// container directly (O(1) — no decode, no per-element loop). This is the
// case that matters in practice: importing a multi-million-ID consecutive
// range should not require building a multi-million-element array first.
// For a bucket only partially covered (or already holding data), the range
// is decoded into a plain UInt16 array and merged via the existing
// sorted_union/sorted_difference + optimize_container pipeline — bounded by
// one bucket's worth of work (<= 65536), matching the cost every Bitmap
// container already pays.

///|
fn full_run_container() -> Container {
  Run([Run::{ start: (0 : UInt16), length: (65535 : UInt16), }])
}

///|
fn range_to_array(lo : Int32, hi : Int32) -> Array[UInt16] {
  let result = []
  for i = lo; i <= hi; i = i + 1 {
    result.push(i.to_uint16())
  }
  result
}

///|
/// Local (bucket-relative) inclusive bounds of `[start, end)` within the
/// bucket identified by `key`. Caller guarantees the bucket actually
/// intersects the range.
fn bucket_local_range(
  key : UInt16,
  start : UInt32,
  end : UInt32,
) -> (Int32, Int32) {
  let bucket_start = combine(key, (0 : UInt16))
  let bucket_end = combine(key, (65535 : UInt16))
  let last = end - 1U
  let lo = if start > bucket_start {
    (start - bucket_start).reinterpret_as_int()
  } else {
    0
  }
  let hi = if last < bucket_end {
    (last - bucket_start).reinterpret_as_int()
  } else {
    65535
  }
  (lo, hi)
}

///|
/// Add local range [lo, hi] to an existing container. A full-bucket range
/// (lo == 0, hi == 65535) always collapses to a single Run regardless of
/// prior contents: the union of "every value in this bucket" with anything
/// already in the bucket is still "every value in this bucket".
fn container_add_range(c : Container, lo : Int32, hi : Int32) -> Container {
  if lo == 0 && hi == 65535 {
    full_run_container()
  } else {
    let existing = container_to_sorted_array(c)
    optimize_container(sorted_union(existing, range_to_array(lo, hi)))
  }
}

///|
/// Whether every value in the local inclusive range [lo, hi] is present in
/// `c`, without decoding the container to an intermediate array.
fn container_contains_range(c : Container, lo : Int32, hi : Int32) -> Bool {
  match c {
    Array(arr) =>
      match binary_search_u16(arr, lo.to_uint16()) {
        NotFound(_) => false
        Found(p) => {
          let idx = p + (hi - lo)
          idx < arr.length() && arr[idx].to_int() == hi
        }
      }
    Bitmap(bm) => {
      for i = lo; i <= hi; i = i + 1 {
        let idx = i / 64
        let bit = i % 64
        if (bm[idx] & (1UL << bit)) == 0UL {
          return false
        }
      }
      true
    }
    Run(runs) => {
      let mut found = false
      for r in runs {
        let start = r.start.to_int()
        let end = start + r.length.to_int()
        if lo >= start && hi <= end {
          found = true
        }
      }
      found
    }
  }
}

///|
/// Add every integer in the half-open range `[start, end)`. Buckets fully
/// covered by the range collapse to a single Run container in O(1); this is
/// the fast path that makes bulk-loading a consecutive ID range (a common
/// pattern for time-series data and sequentially-assigned IDs) cheap.
///
/// The whole range is merged into the container list in one walk, so the cost
/// is O(buckets touched + existing containers) rather than a rebuild of the
/// list per bucket — the difference between a millisecond and half a minute
/// when laying down the entire 32-bit space.
///
/// Note: because `end` is exclusive, this cannot express a range that
/// extends through UInt's maximum value (4294967295) — `end` would have to
/// overflow. Use `add` for that specific boundary value if needed.
pub fn RoaringBitmap::add_range(
  self : RoaringBitmap,
  start : UInt32,
  end : UInt32,
) -> RoaringBitmap {
  if start >= end {
    return self
  }
  let high_start = extract_high(start).to_int()
  let high_end = extract_high(end - 1U).to_int()
  let result_containers = []
  let mut ci = 0
  for high = high_start; high <= high_end; high = high + 1 {
    let key = high.to_uint16()
    let (lo, hi) = bucket_local_range(key, start, end)
    // Carry over every container that sorts before this key.
    while ci < self.containers.length() && self.containers[ci].key < key {
      result_containers.push(self.containers[ci])
      ci = ci + 1
    }
    let has_bucket = ci < self.containers.length() &&
      self.containers[ci].key == key
    let new_container = if has_bucket {
      let existing = self.containers[ci].container
      ci = ci + 1
      container_add_range(existing, lo, hi)
    } else if lo == 0 && hi == 65535 {
      // A bucket the range covers completely is one Run, no decode.
      full_run_container()
    } else {
      optimize_container(range_to_array(lo, hi))
    }
    result_containers.push(HighContainer::{
      key,
      container: new_container,
      cardinality: container_cardinality(new_container),
    })
  }
  while ci < self.containers.length() {
    result_containers.push(self.containers[ci])
    ci = ci + 1
  }
  { containers: result_containers, size: rebuild_size(result_containers), }
}

///|
/// Remove the local inclusive range `[lo, hi]` from a container. Returns
/// `None` when nothing is left, so the caller can drop the bucket outright
/// instead of storing an empty container.
fn container_remove_range(c : Container, lo : Int32, hi : Int32) -> Container? {
  if lo == 0 && hi == 65535 {
    // Removing every value of a bucket leaves nothing behind.
    None
  } else {
    let existing = container_to_sorted_array(c)
    let remaining = sorted_difference(existing, range_to_array(lo, hi))
    if remaining.length() == 0 {
      None
    } else {
      Some(optimize_container(remaining))
    }
  }
}

///|
/// Remove every integer in the half-open range `[start, end)`. A bucket
/// fully covered by the range is dropped outright rather than decoded, and the
/// whole range is merged into the container list in one walk.
pub fn RoaringBitmap::remove_range(
  self : RoaringBitmap,
  start : UInt32,
  end : UInt32,
) -> RoaringBitmap {
  if start >= end {
    return self
  }
  let high_start = extract_high(start).to_int()
  let high_end = extract_high(end - 1U).to_int()
  let result_containers = []
  let mut ci = 0
  for high = high_start; high <= high_end; high = high + 1 {
    let key = high.to_uint16()
    let (lo, hi) = bucket_local_range(key, start, end)
    while ci < self.containers.length() && self.containers[ci].key < key {
      result_containers.push(self.containers[ci])
      ci = ci + 1
    }
    // A key with no bucket has nothing to remove.
    if ci < self.containers.length() && self.containers[ci].key == key {
      let existing = self.containers[ci].container
      ci = ci + 1
      match container_remove_range(existing, lo, hi) {
        None => ()
        Some(new_container) =>
          result_containers.push(HighContainer::{
            key,
            container: new_container,
            cardinality: container_cardinality(new_container),
          })
      }
    }
  }
  while ci < self.containers.length() {
    result_containers.push(self.containers[ci])
    ci = ci + 1
  }
  { containers: result_containers, size: rebuild_size(result_containers), }
}

///|
/// Whether every integer in the half-open range `[start, end)` is present.
/// An empty range (`start >= end`) is trivially contained.
pub fn RoaringBitmap::contains_range(
  self : RoaringBitmap,
  start : UInt32,
  end : UInt32,
) -> Bool {
  if start >= end {
    return true
  }
  let high_start = extract_high(start).to_int()
  let high_end = extract_high(end - 1U).to_int()
  for high = high_start; high <= high_end; high = high + 1 {
    let key = high.to_uint16()
    match find_bucket(self.containers, key) {
      NotFound(_) => return false
      Found(idx) => {
        let (lo, hi) = bucket_local_range(key, start, end)
        if !container_contains_range(self.containers[idx].container, lo, hi) {
          return false
        }
      }
    }
  }
  true
}

///|
/// Create a bitmap containing every integer in the half-open range
/// `[start, end)`.
pub fn RoaringBitmap::from_range(start : UInt32, end : UInt32) -> RoaringBitmap {
  RoaringBitmap::new().add_range(start, end)
}

// ============ Complement within a closed interval ============

///|
/// Local (bucket-relative) inclusive bounds of the *closed* interval
/// `[start, end]` within the bucket identified by `key`. Caller guarantees
/// the bucket actually intersects the interval.
///
/// Unlike `bucket_local_range` this never computes `end - 1`, so it stays
/// correct when `end` is `UInt`'s maximum value — which is exactly the
/// full-universe complement case.
fn bucket_local_closed_range(
  key : UInt16,
  start : UInt32,
  end : UInt32,
) -> (Int32, Int32) {
  let bucket_start = combine(key, (0 : UInt16))
  let bucket_end = combine(key, (65535 : UInt16))
  let lo = if start > bucket_start {
    (start - bucket_start).reinterpret_as_int()
  } else {
    0
  }
  let hi = if end < bucket_end {
    (end - bucket_start).reinterpret_as_int()
  } else {
    65535
  }
  (lo, hi)
}

///|
/// Values in the local inclusive range `[lo, hi]` that are absent from the
/// sorted array `existing`, produced by walking the gaps between `existing`'s
/// values rather than by materializing the whole interval and differencing
/// it — so a full bucket costs O(65536 - cardinality) in output size instead
/// of O(65536) plus a second pass.
///
/// Note the operand still has to be decoded first: `container_to_sorted_array`
/// is itself O(65536) for Run and Bitmap containers, so the saving is on the
/// produced side, not the read side.
fn range_minus_sorted(
  lo : Int32,
  hi : Int32,
  existing : Array[UInt16],
) -> Array[UInt16] {
  let result = []
  let mut cursor = lo
  for v in existing {
    let vi = v.to_int()
    if vi > hi {
      break
    }
    if vi < cursor {
      continue
    }
    while cursor < vi {
      result.push(cursor.to_uint16())
      cursor = cursor + 1
    }
    cursor = vi + 1
  }
  while cursor <= hi {
    result.push(cursor.to_uint16())
    cursor = cursor + 1
  }
  result
}

///|
/// Emit every set bit of one word, tagged with its position in the container.
/// Cost is O(popcount), not O(64): a zero word costs one comparison.
fn emit_set_bits(
  word : UInt64,
  word_start : Int32,
  out : Array[UInt16],
) -> Unit {
  let mut bits = word
  while bits != 0UL {
    let bit = lowest_set_bit(bits)
    out.push((word_start + bit).to_uint16())
    bits = bits & (bits - 1UL)
  }
}

///|
/// Set bits of one word that fall outside the container-relative range
/// [lo, hi]. Both bounds are known to lie inside this word.
fn emit_set_bits_outside(
  word : UInt64,
  word_start : Int32,
  lo : Int32,
  hi : Int32,
  out : Array[UInt16],
) -> Unit {
  let mut bits = word
  while bits != 0UL {
    let bit = lowest_set_bit(bits)
    let value = word_start + bit
    if value < lo || value > hi {
      out.push(value.to_uint16())
    }
    bits = bits & (bits - 1UL)
  }
}

///|
/// A mask with bits `from` through `to` set, for `0 <= from <= to <= 63`.
fn bit_range_mask(from : Int32, to : Int32) -> UInt64 {
  let high = if to >= 63 {
    0xFFFFFFFFFFFFFFFFUL
  } else {
    (1UL << (to + 1)) - 1UL
  }
  let low = if from <= 0 {
    0xFFFFFFFFFFFFFFFFUL
  } else {
    ((1UL << from) - 1UL).lnot()
  }
  high & low
}

///|
/// Values held by the bitmap OUTSIDE the local inclusive range [lo, hi].
/// Only the words the range does not cover are scanned, plus the at most two
/// that straddle its ends, so complementing a whole bucket costs O(1) in
/// words rather than the O(65536) an array decode would pay.
fn bitmap_values_outside_range(
  words : FixedArray[UInt64],
  lo : Int32,
  hi : Int32,
) -> Array[UInt16] {
  let result = []
  let first = lo / 64
  let last = hi / 64
  for w = 0; w < first; w = w + 1 {
    emit_set_bits(words[w], w * 64, result)
  }
  for w = last + 1; w < words.length(); w = w + 1 {
    emit_set_bits(words[w], w * 64, result)
  }
  if first == last {
    emit_set_bits_outside(words[first], first * 64, lo, hi, result)
  } else {
    emit_set_bits_outside(words[first], first * 64, lo, hi, result)
    emit_set_bits_outside(words[last], last * 64, lo, hi, result)
  }
  result
}

///|
/// Values ABSENT from the bitmap inside the local inclusive range [lo, hi].
/// Inverts each covered word and walks its set bits, so a fully populated
/// word costs one comparison and a narrow range only touches the words it
/// actually covers — against the O(65536) decode the array path would pay.
fn bitmap_gaps_in_range(
  words : FixedArray[UInt64],
  lo : Int32,
  hi : Int32,
) -> Array[UInt16] {
  let result = []
  let first_word = lo / 64
  let last_word = hi / 64
  for w = first_word; w <= last_word; w = w + 1 {
    let mut missing = words[w].lnot()
    if missing == 0UL {
      continue
    }
    let from = if w == first_word { lo % 64 } else { 0 }
    let to = if w == last_word { hi % 64 } else { 63 }
    missing = missing & bit_range_mask(from, to)
    let word_start = w * 64
    while missing != 0UL {
      let bit = lowest_set_bit(missing)
      result.push((word_start + bit).to_uint16())
      missing = missing & (missing - 1UL)
    }
  }
  result
}

///|
/// Values held by the runs OUTSIDE the local inclusive range [lo, hi]. Runs
/// are sorted, so this stops as soon as it passes the range.
fn run_values_outside_range(
  runs : Array[Run],
  lo : Int32,
  hi : Int32,
) -> Array[UInt16] {
  let result = []
  for r in runs {
    let start = r.start.to_int()
    if start > hi {
      // Everything from here on is past the range.
      let end = start + r.length.to_int()
      for v = start; v <= end; v = v + 1 {
        result.push(v.to_uint16())
      }
      break
    }
    let end = start + r.length.to_int()
    if end < lo {
      for v = start; v <= end; v = v + 1 {
        result.push(v.to_uint16())
      }
    } else {
      if start < lo {
        for v = start; v < lo; v = v + 1 {
          result.push(v.to_uint16())
        }
      }
      if end > hi {
        for v = hi + 1; v <= end; v = v + 1 {
          result.push(v.to_uint16())
        }
      }
    }
  }
  result
}

///|
/// Values ABSENT from the runs inside the local inclusive range [lo, hi],
/// produced by walking the gaps between them. Cost is O(runs + values
/// emitted) instead of decoding the runs into an array first.
fn run_gaps_in_range(
  runs : Array[Run],
  lo : Int32,
  hi : Int32,
) -> Array[UInt16] {
  let result = []
  let mut cursor = lo
  for r in runs {
    let start = r.start.to_int()
    if start > hi {
      break
    }
    let end = start + r.length.to_int()
    if end < lo {
      continue
    }
    if start > cursor {
      let stop = if start - 1 < hi { start - 1 } else { hi }
      for v = cursor; v <= stop; v = v + 1 {
        result.push(v.to_uint16())
      }
    }
    if end + 1 > cursor {
      cursor = end + 1
    }
    if cursor > hi {
      break
    }
  }
  for v = cursor; v <= hi; v = v + 1 {
    result.push(v.to_uint16())
  }
  result
}

///|
/// The two halves of a complement within [lo, hi]: the values that survive
/// because they sit outside the interval, and the values that arrive because
/// they were absent inside it. Both come back ascending and duplicate-free,
/// and they are disjoint by construction, which is what `sorted_union` needs.
///
/// Only the Array case decodes: Bitmap and Run containers are read in place,
/// so complementing a dense bucket no longer costs a 65536-element array.
fn container_flip_parts(
  c : Container,
  lo : Int32,
  hi : Int32,
) -> (Array[UInt16], Array[UInt16]) {
  match c {
    Array(arr) => {
      let kept = []
      for v in arr {
        let vi = v.to_int()
        if vi < lo || vi > hi {
          kept.push(v)
        }
      }
      (kept, range_minus_sorted(lo, hi, arr))
    }
    Bitmap(words) =>
      (
        bitmap_values_outside_range(words, lo, hi),
        bitmap_gaps_in_range(words, lo, hi),
      )
    Run(runs) =>
      (run_values_outside_range(runs, lo, hi), run_gaps_in_range(runs, lo, hi))
  }
}

///|
/// Complement of `c` restricted to the local inclusive range `[lo, hi]`.
/// Returns `None` when the result is empty, so the caller can drop the
/// bucket outright instead of storing an empty container.
///
/// Note there is no cheap "whole bucket" shortcut here, unlike
/// `container_add_range`: unioning a bucket with its full range collapses to
/// that range, but complementing a bucket over its full range yields
/// "everything the bucket did not already hold", which is only empty when
/// the bucket held everything to begin with.
fn container_flip_range(c : Container, lo : Int32, hi : Int32) -> Container? {
  let (kept, added) = container_flip_parts(c, lo, hi)
  let merged = sorted_union(kept, added)
  if merged.length() == 0 {
    None
  } else {
    Some(optimize_container(merged))
  }
}

///|
fn flip_range_in_bucket(
  containers : Array[HighContainer],
  key : UInt16,
  lo : Int32,
  hi : Int32,
) -> Array[HighContainer] {
  match find_bucket(containers, key) {
    NotFound(pos) => {
      // Nothing stored for this key yet, so the complement is simply the
      // whole interval.
      let new_container = optimize_container(range_to_array(lo, hi))
      let new_bucket = HighContainer::{
        key,
        container: new_container,
        cardinality: container_cardinality(new_container),
      }
      let new_containers = []
      for i = 0; i < pos; i = i + 1 {
        new_containers.push(containers[i])
      }
      new_containers.push(new_bucket)
      for i = pos; i < containers.length(); i = i + 1 {
        new_containers.push(containers[i])
      }
      new_containers
    }
    Found(idx) =>
      match container_flip_range(containers[idx].container, lo, hi) {
        None => {
          let result = []
          for i = 0; i < containers.length(); i = i + 1 {
            if i != idx {
              result.push(containers[i])
            }
          }
          result
        }
        Some(new_container) => {
          let new_bucket = HighContainer::{
            key,
            container: new_container,
            cardinality: container_cardinality(new_container),
          }
          let new_containers = containers.copy()
          new_containers[idx] = new_bucket
          new_containers
        }
      }
  }
}

///|
/// Complement within the closed interval `[start, end]` — both bounds
/// inclusive, matching CRoaring's `roaring_bitmap_flip(ra, start, end)`.
///
/// Values present inside the interval are dropped, values absent from it are
/// added, and values outside the interval never appear in the result. In
/// other words the result is `[start, end] \ self`, restricted to `[start,
/// end]`.
///
/// An inverted interval (`start > end`) is a no-op and returns the receiver
/// unchanged, matching CRoaring and this package's own `add_range` /
/// `remove_range`. Returning an empty bitmap instead would silently discard
/// every value, which is a harsh outcome for what is usually a swapped pair
/// of bounds.
///
/// Note the contrast with `add_range`/`remove_range`, which take half-open
/// intervals: `flip` is closed because that is what the reference
/// implementations expose, and because a closed interval is the only way to
/// name a range that runs through `UInt`'s maximum value.
///
/// Be aware that `size()` returns a 32-bit signed `Int`, so a bitmap holding
/// more than 2147483647 elements cannot report its own cardinality. Flipping
/// the entire 32-bit universe (`flip(0U, 4294967295U)`) is therefore
/// expressible but not countable — prefer the narrowest interval that
/// answers your question.
pub fn RoaringBitmap::flip(
  self : RoaringBitmap,
  start : UInt32,
  end : UInt32,
) -> RoaringBitmap {
  if start > end {
    return self
  }
  let high_start = extract_high(start).to_int()
  let high_end = extract_high(end).to_int()
  let mut containers = self.containers
  for high = high_start; high <= high_end; high = high + 1 {
    let key = high.to_uint16()
    let (lo, hi) = bucket_local_closed_range(key, start, end)
    containers = flip_range_in_bucket(containers, key, lo, hi)
  }
  { containers, size: rebuild_size(containers), }
}
