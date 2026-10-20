// Lazy iteration plus rank/select — the "which element is where" queries
// that to_array()'s all-at-once decode doesn't offer.

// ============ container-level rank / select ============

///|
/// Count of elements in `c` that are <= `value` (0-indexed rank).
fn container_rank(c : Container, value : UInt16) -> Int32 {
  match c {
    Array(arr) =>
      match binary_search_u16(arr, value) {
        Found(idx) => idx + 1
        NotFound(pos) => pos
      }
    Bitmap(bm) => {
      let v = value.to_int()
      let word_idx = v / 64
      let bit = v % 64
      let mut count = 0
      for i = 0; i < word_idx; i = i + 1 {
        count = count + popcount64(bm[i])
      }
      let mask = if bit == 63 {
        0xFFFFFFFFFFFFFFFFUL
      } else {
        (1UL << (bit + 1)) - 1UL
      }
      count + popcount64(bm[word_idx] & mask)
    }
    Run(runs) => {
      let v = value.to_int()
      let mut count = 0
      for i = 0; i < runs.length(); i = i + 1 {
        let r = runs[i]
        let start = r.start.to_int()
        let end = start + r.length.to_int()
        if end <= v {
          count = count + r.length.to_int() + 1
        } else if start <= v {
          count = count + (v - start + 1)
        }
      }
      count
    }
  }
}

///|
/// The value at `index` (0-indexed) among the container's elements in
/// ascending order. Caller guarantees `0 <= index < container_cardinality(c)`.
fn container_select(c : Container, index : Int32) -> UInt16 {
  match c {
    Array(arr) => arr[index]
    Bitmap(bm) => {
      let mut remaining = index
      for word_idx = 0; word_idx < bm.length(); word_idx = word_idx + 1 {
        let word_count = popcount64(bm[word_idx])
        if remaining < word_count {
          let mut word = bm[word_idx]
          let mut bit = 0
          while word != 0UL {
            if (word & 1UL) != 0UL {
              if remaining == 0 {
                return (word_idx * 64 + bit).to_uint16()
              }
              remaining = remaining - 1
            }
            word = word >> 1
            bit = bit + 1
          }
        } else {
          remaining = remaining - word_count
        }
      }
      // Unreachable while the caller honours the documented contract. Abort
      // rather than fall through to 0, which would be a silently wrong answer
      // for whoever breaks that contract next.
      abort("container_select: index out of range for a Bitmap container")
    }
    Run(runs) => {
      let mut remaining = index
      for i = 0; i < runs.length(); i = i + 1 {
        let r = runs[i]
        let len = r.length.to_int() + 1
        if remaining < len {
          return (r.start.to_int() + remaining).to_uint16()
        }
        remaining = remaining - len
      }
      abort("container_select: index out of range for a Run container")
    }
  }
}

// ============ public API ============

///|
/// An iterator over every element in ascending order. Decodes one bucket's
/// container at a time rather than materializing the whole bitmap up front
/// (as `to_array()` does), so `bm.iter().take(n)` or `bm.iter().find_first(f)`
/// can stop without paying to decode buckets past where iteration stopped.
pub fn RoaringBitmap::iter(self : RoaringBitmap) -> Iter[UInt32] {
  let containers = self.containers
  let mut bucket_idx = 0
  let mut current : Array[UInt16] = []
  let mut current_key : UInt16 = (0 : UInt16)
  let mut pos = 0
  Iter::new(
    fn() {
      while pos >= current.length() {
        if bucket_idx >= containers.length() {
          return None
        }
        let hc = containers[bucket_idx]
        current = container_to_sorted_array(hc.container)
        current_key = hc.key
        pos = 0
        bucket_idx = bucket_idx + 1
      }
      let value = combine(current_key, current[pos])
      pos = pos + 1
      Some(value)
    },
    // `size_hint` is an `Int` and a bitmap can hold more values than that, so
    // clamp rather than wrap. The hint is advisory: `iter` is lazy and works
    // on a bitmap of any size until the caller tries to collect it.
    size_hint=size_as_int(self.size),
  )
}

///|
/// Number of elements <= `value` (CRoaring calls this `rank`). For example,
/// `bm.rank(bm.max().unwrap())` equals `bm.size()`.
///
/// Returns `Int64` for the same reason the `*_cardinality` methods do: a
/// bitmap can hold up to 2^32 values, which does not fit in MoonBit's 32-bit
/// signed `Int`, and a wrapped accumulator would report a negative count.
/// CRoaring's counterpart returns `uint64_t`.
pub fn RoaringBitmap::rank(self : RoaringBitmap, value : UInt32) -> Int64 {
  let high = extract_high(value)
  let low = extract_low(value)
  let mut count = 0L
  for i = 0; i < self.containers.length(); i = i + 1 {
    let hc = self.containers[i]
    if hc.key < high {
      count = count + Int64::from_int(hc.cardinality)
    } else if hc.key == high {
      return count + Int64::from_int(container_rank(hc.container, low))
    } else {
      return count
    }
  }
  count
}

///|
/// The `index`-th smallest element (0-indexed), or `None` if `index` is out
/// of bounds. Inverse of `rank` in the sense that
/// `bm.select(bm.rank(x).to_int() - 1) == Some(x)` whenever `bm.contains(x)`.
///
/// The bounds check tests `containers` rather than the cached cardinality, so
/// an accumulation that overflowed on the way in cannot make every index look
/// out of range on a provably non-empty bitmap.
pub fn RoaringBitmap::select(self : RoaringBitmap, index : Int32) -> UInt32? {
  if index < 0 || self.containers.length() == 0 {
    return None
  }
  let mut remaining = index
  for i = 0; i < self.containers.length(); i = i + 1 {
    let hc = self.containers[i]
    if remaining < hc.cardinality {
      return Some(combine(hc.key, container_select(hc.container, remaining)))
    }
    remaining = remaining - hc.cardinality
  }
  None
}

///|
/// Count of elements in `c` within the local inclusive range [lo, hi].
/// `container_rank` counts everything at or below a value, so this is the
/// difference of two ranks; `lo == 0` needs no subtraction because there is
/// nothing below it.
fn container_rank_range(c : Container, lo : Int32, hi : Int32) -> Int32 {
  let below = if lo <= 0 { 0 } else { container_rank(c, (lo - 1).to_uint16()) }
  container_rank(c, hi.to_uint16()) - below
}

///|
/// Number of elements in the half-open range `[start, end)`.
///
/// Half-open to match `add_range`, `remove_range` and `contains_range` — note
/// that the reference implementations disagree with each other here, so this
/// follows the package's own convention rather than either of them.
///
/// Walks only the buckets the range touches and counts inside each one, so it
/// never decodes a bucket outside the range. Cheaper and less error-prone than
/// `rank(end - 1) - rank(start - 1)`, which also has to special-case `start`.
///
/// Returns `Int64` for the same reason `rank` does.
pub fn RoaringBitmap::range_cardinality(
  self : RoaringBitmap,
  start : UInt32,
  end : UInt32,
) -> Int64 {
  if start >= end {
    return 0L
  }
  let high_start = extract_high(start).to_int()
  let high_end = extract_high(end - 1U).to_int()
  let mut count = 0L
  for high = high_start; high <= high_end; high = high + 1 {
    let key = high.to_uint16()
    match find_bucket(self.containers, key) {
      NotFound(_) => ()
      Found(idx) => {
        let (lo, hi) = bucket_local_range(key, start, end)
        count = count +
          Int64::from_int(
            container_rank_range(self.containers[idx].container, lo, hi),
          )
      }
    }
  }
  count
}
