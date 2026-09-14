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
fn range_to_array(lo : Int, hi : Int) -> Array[UInt16] {
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
fn bucket_local_range(key : UInt16, start : UInt, end : UInt) -> (Int, Int) {
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
fn container_add_range(c : Container, lo : Int, hi : Int) -> Container {
  if lo == 0 && hi == 65535 {
    full_run_container()
  } else {
    let existing = container_to_sorted_array(c)
    optimize_container(sorted_union(existing, range_to_array(lo, hi)))
  }
}

///|
fn add_range_to_bucket(
  containers : Array[HighContainer],
  key : UInt16,
  lo : Int,
  hi : Int,
) -> Array[HighContainer] {
  match find_bucket(containers, key) {
    Found(idx) => {
      let bucket = containers[idx]
      let new_container = container_add_range(bucket.container, lo, hi)
      let new_bucket = HighContainer::{
        key,
        container: new_container,
        cardinality: container_cardinality(new_container),
      }
      let new_containers = containers.copy()
      new_containers[idx] = new_bucket
      new_containers
    }
    NotFound(pos) => {
      let new_container = if lo == 0 && hi == 65535 {
        full_run_container()
      } else {
        optimize_container(range_to_array(lo, hi))
      }
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
  }
}

///|
fn remove_range_from_bucket(
  containers : Array[HighContainer],
  key : UInt16,
  lo : Int,
  hi : Int,
) -> Array[HighContainer] {
  match find_bucket(containers, key) {
    NotFound(_) => containers
    Found(idx) => {
      let drop_bucket = fn() {
        let result = []
        for i = 0; i < containers.length(); i = i + 1 {
          if i != idx {
            result.push(containers[i])
          }
        }
        result
      }
      if lo == 0 && hi == 65535 {
        drop_bucket()
      } else {
        let bucket = containers[idx]
        let existing = container_to_sorted_array(bucket.container)
        let new_arr = sorted_difference(existing, range_to_array(lo, hi))
        if new_arr.length() == 0 {
          drop_bucket()
        } else {
          let new_container = optimize_container(new_arr)
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
}

///|
/// Whether every value in the local inclusive range [lo, hi] is present in
/// `c`, without decoding the container to an intermediate array.
fn container_contains_range(c : Container, lo : Int, hi : Int) -> Bool {
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
/// Note: because `end` is exclusive, this cannot express a range that
/// extends through UInt's maximum value (4294967295) — `end` would have to
/// overflow. Use `add` for that specific boundary value if needed.
pub fn RoaringBitmap::add_range(
  self : RoaringBitmap,
  start : UInt,
  end : UInt,
) -> RoaringBitmap {
  if start >= end {
    return self
  }
  let high_start = extract_high(start).to_int()
  let high_end = extract_high(end - 1U).to_int()
  let mut containers = self.containers
  for high = high_start; high <= high_end; high = high + 1 {
    let key = high.to_uint16()
    let (lo, hi) = bucket_local_range(key, start, end)
    containers = add_range_to_bucket(containers, key, lo, hi)
  }
  { containers, size: rebuild_size(containers), }
}

///|
/// Remove every integer in the half-open range `[start, end)`. A bucket
/// fully covered by the range is dropped outright rather than decoded.
pub fn RoaringBitmap::remove_range(
  self : RoaringBitmap,
  start : UInt,
  end : UInt,
) -> RoaringBitmap {
  if start >= end {
    return self
  }
  let high_start = extract_high(start).to_int()
  let high_end = extract_high(end - 1U).to_int()
  let mut containers = self.containers
  for high = high_start; high <= high_end; high = high + 1 {
    let key = high.to_uint16()
    let (lo, hi) = bucket_local_range(key, start, end)
    containers = remove_range_from_bucket(containers, key, lo, hi)
  }
  { containers, size: rebuild_size(containers), }
}

///|
/// Whether every integer in the half-open range `[start, end)` is present.
/// An empty range (`start >= end`) is trivially contained.
pub fn RoaringBitmap::contains_range(
  self : RoaringBitmap,
  start : UInt,
  end : UInt,
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
pub fn RoaringBitmap::from_range(start : UInt, end : UInt) -> RoaringBitmap {
  RoaringBitmap::new().add_range(start, end)
}
