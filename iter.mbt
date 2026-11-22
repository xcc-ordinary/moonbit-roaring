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
/// First index in an ascending array whose value is >= `value`, or the array
/// length when there is none.
fn first_index_at_or_above(arr : Array[UInt16], value : UInt16) -> Int32 {
  match binary_search_u16(arr, value) {
    Found(idx) => idx
    NotFound(pos) => pos
  }
}

///|
/// A lazy cursor over one bucket's combined 32-bit values, in ascending order.
///
/// The walk used to decode each bucket with `container_to_sorted_array` before
/// yielding anything, so a Bitmap or Run bucket materialized up to 65536
/// elements even for `iter_from(x).take(1)`. The cursor keeps a
/// per-representation position and produces one value at a time: an index into
/// the Array, Kernighan bit extraction within the current Bitmap word, or a
/// countdown within the current Run. No intermediate array is built, and the
/// combined value comes back in a single Option that the walk reuses as-is, so
/// full iteration stays close to the old decode-then-index walk while seeks
/// stay lazy. A struct method keeps the per-element call direct (no indirect
/// closure dispatch).
priv struct LazyCursor {
  key : UInt16
  container : Container
  mut arr_pos : Int32
  mut word_idx : Int32
  mut word_rest : UInt64
  mut run_idx : Int32
  mut run_next : Int32
  mut run_remaining : Int32
}

///|
fn LazyCursor::new(key : UInt16, container : Container) -> LazyCursor {
  LazyCursor::{
    key,
    container,
    arr_pos: 0,
    word_idx: 0,
    word_rest: 0UL,
    run_idx: 0,
    run_next: 0,
    run_remaining: 0,
  }
}

///|
/// Next combined value, or None once the bucket is exhausted.
fn LazyCursor::next(self : LazyCursor) -> UInt32? {
  match self.container {
    Array(arr) =>
      if self.arr_pos >= arr.length() {
        None
      } else {
        let v = arr[self.arr_pos]
        self.arr_pos = self.arr_pos + 1
        Some(combine(self.key, v))
      }
    Bitmap(words) => {
      if self.word_rest == 0UL {
        // Skip empty words; each word is visited once across the whole drain.
        while self.word_idx < words.length() && words[self.word_idx] == 0UL {
          self.word_idx = self.word_idx + 1
        }
        if self.word_idx >= words.length() {
          return None
        }
        self.word_rest = words[self.word_idx]
      }
      let bit = lowest_set_bit(self.word_rest)
      let v = (self.word_idx * 64 + bit).to_uint16()
      self.word_rest = self.word_rest & (self.word_rest - 1UL)
      if self.word_rest == 0UL {
        self.word_idx = self.word_idx + 1
      }
      Some(combine(self.key, v))
    }
    Run(runs) => {
      // The current run is cached as a next-value + countdown, so the hot loop
      // does not touch the runs array per element.
      if self.run_remaining == 0 {
        if self.run_idx >= runs.length() {
          return None
        }
        let r = runs[self.run_idx]
        self.run_next = r.start.to_int()
        self.run_remaining = r.length.to_int() + 1
        self.run_idx = self.run_idx + 1
      }
      let v = self.run_next.to_uint16()
      self.run_next = self.run_next + 1
      self.run_remaining = self.run_remaining - 1
      Some(combine(self.key, v))
    }
  }
}

///|
/// Position the cursor at the first low value >= `low`, without decoding the
/// container: a binary search for Array, a masked word for Bitmap, a binary
/// search over run ends for Run.
fn LazyCursor::seek(self : LazyCursor, low : UInt16) -> Unit {
  match self.container {
    Array(arr) => self.arr_pos = first_index_at_or_above(arr, low)
    Bitmap(words) => {
      let v = low.to_int()
      let wi = v / 64
      self.word_idx = wi
      // Clear the bits below `low` inside its word; next() skips ahead when
      // the masked word is empty.
      self.word_rest = words[wi] & (0xFFFFFFFFFFFFFFFFUL << (v % 64))
      if self.word_rest == 0UL {
        self.word_idx = wi + 1
      }
    }
    Run(runs) => {
      let v = low.to_int()
      // Run ends ascend too (runs are sorted and disjoint), so binary search
      // for the first run whose end reaches `low`.
      let mut lo_i = 0
      let mut hi_i = runs.length()
      while lo_i < hi_i {
        let mid = (lo_i + hi_i) / 2
        let r = runs[mid]
        if r.start.to_int() + r.length.to_int() < v {
          lo_i = mid + 1
        } else {
          hi_i = mid
        }
      }
      // When the seek is past every run, lo_i == runs.length(): leave the
      // cursor exhausted instead of letting next() reload run 0.
      self.run_idx = lo_i
      self.run_remaining = 0
      if lo_i < runs.length() {
        let r = runs[lo_i]
        let s = r.start.to_int()
        self.run_next = if s >= v { s } else { v }
        self.run_remaining = s + r.length.to_int() - self.run_next + 1
        self.run_idx = lo_i + 1
      }
    }
  }
}

///|
/// The lazy walk shared by `iter` and `iter_from`.
///
/// `first` is an already-positioned generator for the first bucket, or None to
/// begin by opening bucket `next_bucket` on the first call — which is what
/// `iter` wants: it costs nothing until the first element is actually
/// requested, and each bucket is opened only when the walk reaches it, one
/// value at a time.
fn walk_containers(
  containers : Array[HighContainer],
  first : LazyCursor?,
  next_bucket : Int32,
  size : Int64,
) -> Iter[UInt32] {
  let mut bucket_idx = next_bucket
  let mut current = first
  Iter(
    fn() {
      let mut result : UInt32? = None
      let mut done = false
      while !done {
        match current {
          Some(cursor) => {
            // Reuse the cursor's Option as-is: wrapping it again would
            // allocate a second box per element.
            result = cursor.next()
            match result {
              Some(_) => done = true
              None => current = None
            }
          }
          None =>
            if bucket_idx >= containers.length() {
              done = true
            } else {
              let hc = containers[bucket_idx]
              current = Some(LazyCursor::new(hc.key, hc.container))
              bucket_idx = bucket_idx + 1
            }
        }
      }
      result
    },
    // `size_hint` is an `Int` and a bitmap can hold more values than that, so
    // clamp rather than wrap. The hint is advisory — and an upper bound for
    // `iter_from`, which starts partway in.
    size_hint=size_as_int(size),
  )
}

///|
/// An iterator over every element in ascending order. Opens one bucket at a
/// time and yields its values lazily (no bucket is materialized as an array),
/// so `bm.iter().take(n)` or `bm.iter().find_first(f)` can stop without paying
/// for buckets — or bucket elements — past where iteration stopped.
pub fn RoaringBitmap::iter(self : RoaringBitmap) -> Iter[UInt32] {
  walk_containers(self.containers, None, 0, self.size)
}

///|
/// An iterator over every element >= `start`, in ascending order.
///
/// "The next value at or above x" is the core primitive of a posting-list
/// merge, a windowed scan, or a skip-list-style probe. Without it the only way
/// to express the query is `iter().find_first(v >= x)`, which decodes every
/// bucket before x on the way.
///
/// Seeks with a binary search rather than a walk: the bucket holding `start`
/// is found in O(log containers), and the position inside it is set without
/// decoding — an index for Array, a masked word for Bitmap, a run offset for
/// Run. Everything stays lazy, so `iter_from(x).take(n)` pays only for the
/// seek and the n values, never for a whole bucket.
///
/// The size hint is an upper bound rather than exact, since iteration begins
/// partway in.
pub fn RoaringBitmap::iter_from(
  self : RoaringBitmap,
  start : UInt32,
) -> Iter[UInt32] {
  let containers = self.containers
  let start_high = extract_high(start)
  let start_low = extract_low(start)
  // The first bucket that can hold a value >= start is the one holding
  // `start`'s high key, or the next one along when there is no such bucket.
  let first_bucket = match find_bucket(containers, start_high) {
    Found(idx) => idx
    NotFound(pos) => pos
  }
  if first_bucket >= containers.length() {
    // `start` is past every value the bitmap holds.
    return walk_containers(containers, None, containers.length(), self.size)
  }
  let hc = containers[first_bucket]
  let cursor = LazyCursor::new(hc.key, hc.container)
  if hc.key == start_high {
    cursor.seek(start_low)
  }
  walk_containers(containers, Some(cursor), first_bucket + 1, self.size)
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
      count = count + hc.cardinality.to_int64()
    } else if hc.key == high {
      return count + container_rank(hc.container, low).to_int64()
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
  let high_start = extract_high(start)
  let high_end = extract_high(end - 1U)
  let mut count = 0L
  // Walk the containers that actually exist, skipping keys below the interval
  // and stopping past it, rather than probing every possible key in
  // [high_start, high_end] — a wide interval over a sparse bitmap used to cost
  // up to 65536 bucket lookups even when only a handful of buckets are present.
  for hc in self.containers {
    if hc.key < high_start {
      continue
    }
    if hc.key > high_end {
      break
    }
    let (lo, hi) = bucket_local_range(hc.key, start, end)
    count = count + container_rank_range(hc.container, lo, hi).to_int64()
  }
  count
}
