// Public API for RoaringBitmap
// A 32-bit value is split into a 16-bit high key (which HighContainer bucket)
// and a 16-bit low value (stored inside that bucket's Container).

// ============ Sorted HighContainer array primitives ============

///|
fn find_bucket(containers : Array[HighContainer], key : UInt16) -> SearchResult {
  let mut left = 0
  let mut right = containers.length()
  while left < right {
    let mid = (left + right) / 2
    let mid_key = containers[mid].key
    if mid_key == key {
      return Found(mid)
    } else if mid_key < key {
      left = mid + 1
    } else {
      right = mid
    }
  }
  NotFound(left)
}

///|
fn rebuild_size(containers : Array[HighContainer]) -> Int {
  let mut total = 0
  for hc in containers {
    total = total + hc.cardinality
  }
  total
}

// ============ Construction ============

///|
/// Create an empty RoaringBitmap
pub fn RoaringBitmap::new() -> RoaringBitmap {
  { containers: [], size: 0, }
}

///|
/// Create from a single value
pub fn RoaringBitmap::singleton(value : UInt) -> RoaringBitmap {
  RoaringBitmap::new().add(value)
}

///|
/// Create from an array of values
pub fn RoaringBitmap::from_array(values : Array[UInt]) -> RoaringBitmap {
  RoaringBitmap::new().add_many(values)
}

// ============ Basic Operations ============

///|
/// Add a single element. Decodes the target bucket's container, inserts the
/// value, then re-optimizes container representation (may upgrade/downgrade
/// between Array/Bitmap/Run).
pub fn RoaringBitmap::add(self : RoaringBitmap, value : UInt) -> RoaringBitmap {
  let high = extract_high(value)
  let low = extract_low(value)
  match find_bucket(self.containers, high) {
    Found(idx) => {
      let bucket = self.containers[idx]
      if container_contains(bucket.container, low) {
        self
      } else {
        let new_container = container_add(bucket.container, low)
        let new_bucket = HighContainer::{
          key: high,
          container: new_container,
          cardinality: container_cardinality(new_container),
        }
        let new_containers = self.containers.copy()
        new_containers[idx] = new_bucket
        { containers: new_containers, size: self.size + 1, }
      }
    }
    NotFound(pos) => {
      let new_container = container_from_sorted_array([low])
      let new_bucket = HighContainer::{
        key: high,
        container: new_container,
        cardinality: 1,
      }
      let new_containers = []
      for i = 0; i < pos; i = i + 1 {
        new_containers.push(self.containers[i])
      }
      new_containers.push(new_bucket)
      for i = pos; i < self.containers.length(); i = i + 1 {
        new_containers.push(self.containers[i])
      }
      { containers: new_containers, size: self.size + 1, }
    }
  }
}

///|
/// Add multiple elements. Groups by high key first so each bucket is
/// re-optimized once instead of once per inserted value.
pub fn RoaringBitmap::add_many(
  self : RoaringBitmap,
  values : Array[UInt],
) -> RoaringBitmap {
  let mut result = self
  // Group incoming values by high key, preserving first-seen order of keys.
  let keys : Array[UInt16] = []
  let grouped : Array[Array[UInt16]] = []
  for v in values {
    let high = extract_high(v)
    let low = extract_low(v)
    let mut found_idx = -1
    for i = 0; i < keys.length(); i = i + 1 {
      if keys[i] == high {
        found_idx = i
      }
    }
    if found_idx == -1 {
      keys.push(high)
      grouped.push([low])
    } else {
      grouped[found_idx].push(low)
    }
  }
  for i = 0; i < keys.length(); i = i + 1 {
    let high = keys[i]
    let lows = grouped[i]
    result = result.add_bucket_values(high, lows)
  }
  result
}

///|
/// Internal: merge a batch of low-16-bit values into a single bucket.
fn RoaringBitmap::add_bucket_values(
  self : RoaringBitmap,
  high : UInt16,
  lows : Array[UInt16],
) -> RoaringBitmap {
  match find_bucket(self.containers, high) {
    Found(idx) => {
      let bucket = self.containers[idx]
      let existing = container_to_sorted_array(bucket.container)
      let mut merged = existing
      for v in lows {
        merged = sorted_insert(merged, v)
      }
      let new_container = optimize_container(merged)
      let new_bucket = HighContainer::{
        key: high,
        container: new_container,
        cardinality: container_cardinality(new_container),
      }
      let new_containers = self.containers.copy()
      new_containers[idx] = new_bucket
      { containers: new_containers, size: rebuild_size(new_containers), }
    }
    NotFound(pos) => {
      let mut dedup : Array[UInt16] = []
      for v in lows {
        dedup = sorted_insert(dedup, v)
      }
      let new_container = optimize_container(dedup)
      let new_bucket = HighContainer::{
        key: high,
        container: new_container,
        cardinality: container_cardinality(new_container),
      }
      let new_containers = []
      for i = 0; i < pos; i = i + 1 {
        new_containers.push(self.containers[i])
      }
      new_containers.push(new_bucket)
      for i = pos; i < self.containers.length(); i = i + 1 {
        new_containers.push(self.containers[i])
      }
      { containers: new_containers, size: rebuild_size(new_containers), }
    }
  }
}

///|
/// Remove a single element
pub fn RoaringBitmap::remove(
  self : RoaringBitmap,
  value : UInt,
) -> RoaringBitmap {
  let high = extract_high(value)
  let low = extract_low(value)
  match find_bucket(self.containers, high) {
    NotFound(_) => self
    Found(idx) => {
      let bucket = self.containers[idx]
      if !container_contains(bucket.container, low) {
        self
      } else {
        let new_container = container_remove(bucket.container, low)
        let new_cardinality = container_cardinality(new_container)
        if new_cardinality == 0 {
          let new_containers = []
          for i = 0; i < self.containers.length(); i = i + 1 {
            if i != idx {
              new_containers.push(self.containers[i])
            }
          }
          { containers: new_containers, size: self.size - 1, }
        } else {
          let new_bucket = HighContainer::{
            key: high,
            container: new_container,
            cardinality: new_cardinality,
          }
          let new_containers = self.containers.copy()
          new_containers[idx] = new_bucket
          { containers: new_containers, size: self.size - 1, }
        }
      }
    }
  }
}

///|
/// Check if element exists
pub fn RoaringBitmap::contains(self : RoaringBitmap, value : UInt) -> Bool {
  let high = extract_high(value)
  let low = extract_low(value)
  match find_bucket(self.containers, high) {
    NotFound(_) => false
    Found(idx) => container_contains(self.containers[idx].container, low)
  }
}

///|
/// Get cardinality (number of elements)
pub fn RoaringBitmap::size(self : RoaringBitmap) -> Int {
  self.size
}

///|
/// Check if empty
pub fn RoaringBitmap::is_empty(self : RoaringBitmap) -> Bool {
  self.size == 0
}

///|
/// Minimum element, if any
pub fn RoaringBitmap::min(self : RoaringBitmap) -> UInt? {
  if self.containers.length() == 0 {
    None
  } else {
    let first = self.containers[0]
    match container_min(first.container) {
      Some(low) => Some(combine(first.key, low))
      None => None
    }
  }
}

///|
/// Maximum element, if any
pub fn RoaringBitmap::max(self : RoaringBitmap) -> UInt? {
  if self.containers.length() == 0 {
    None
  } else {
    let last = self.containers[self.containers.length() - 1]
    match container_max(last.container) {
      Some(low) => Some(combine(last.key, low))
      None => None
    }
  }
}

// ============ Set Operations ============
//
// All four operations merge-walk both sorted container-key arrays. When keys
// match, the underlying containers are combined via the container_* helpers,
// which always finish by calling optimize_container — so the result never
// carries a stale container type forward.

///|
/// Union: A ∪ B
pub fn RoaringBitmap::union(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> RoaringBitmap {
  let result_containers = []
  let mut i = 0
  let mut j = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      result_containers.push(a)
      i = i + 1
    } else if a.key > b.key {
      result_containers.push(b)
      j = j + 1
    } else {
      let merged = container_union(a.container, b.container)
      result_containers.push(HighContainer::{
        key: a.key,
        container: merged,
        cardinality: container_cardinality(merged),
      })
      i = i + 1
      j = j + 1
    }
  }
  while i < self.containers.length() {
    result_containers.push(self.containers[i])
    i = i + 1
  }
  while j < other.containers.length() {
    result_containers.push(other.containers[j])
    j = j + 1
  }
  { containers: result_containers, size: rebuild_size(result_containers), }
}

///|
/// Intersection: A ∩ B
pub fn RoaringBitmap::intersect(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> RoaringBitmap {
  let result_containers = []
  let mut i = 0
  let mut j = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      i = i + 1
    } else if a.key > b.key {
      j = j + 1
    } else {
      let merged = container_intersect(a.container, b.container)
      let card = container_cardinality(merged)
      if card > 0 {
        result_containers.push(HighContainer::{
          key: a.key,
          container: merged,
          cardinality: card,
        })
      }
      i = i + 1
      j = j + 1
    }
  }
  { containers: result_containers, size: rebuild_size(result_containers), }
}

///|
/// Difference: A \ B
pub fn RoaringBitmap::difference(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> RoaringBitmap {
  let result_containers = []
  let mut i = 0
  let mut j = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      result_containers.push(a)
      i = i + 1
    } else if a.key > b.key {
      j = j + 1
    } else {
      let merged = container_difference(a.container, b.container)
      let card = container_cardinality(merged)
      if card > 0 {
        result_containers.push(HighContainer::{
          key: a.key,
          container: merged,
          cardinality: card,
        })
      }
      i = i + 1
      j = j + 1
    }
  }
  while i < self.containers.length() {
    result_containers.push(self.containers[i])
    i = i + 1
  }
  { containers: result_containers, size: rebuild_size(result_containers), }
}

///|
/// Symmetric difference: A ⊕ B
pub fn RoaringBitmap::xor(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> RoaringBitmap {
  let result_containers = []
  let mut i = 0
  let mut j = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      result_containers.push(a)
      i = i + 1
    } else if a.key > b.key {
      result_containers.push(b)
      j = j + 1
    } else {
      let merged = container_xor(a.container, b.container)
      let card = container_cardinality(merged)
      if card > 0 {
        result_containers.push(HighContainer::{
          key: a.key,
          container: merged,
          cardinality: card,
        })
      }
      i = i + 1
      j = j + 1
    }
  }
  while i < self.containers.length() {
    result_containers.push(self.containers[i])
    i = i + 1
  }
  while j < other.containers.length() {
    result_containers.push(other.containers[j])
    j = j + 1
  }
  { containers: result_containers, size: rebuild_size(result_containers), }
}

// ============ Comparison ============

///|
/// Check if two bitmaps contain the same elements
pub fn RoaringBitmap::equals(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Bool {
  if self.size != other.size {
    return false
  }
  self.to_array() == other.to_array()
}

///|
/// Check if self is a subset of other
pub fn RoaringBitmap::is_subset(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Bool {
  self.intersect(other).size() == self.size
}

// ============ Serialization (CRoaring-compatible) ============
//
// serialize() / deserialize() are implemented in serialize.mbt

// ============ Conversion ============

///|
/// Convert to sorted array
pub fn RoaringBitmap::to_array(self : RoaringBitmap) -> Array[UInt] {
  let result = []
  for hc in self.containers {
    let lows = container_to_sorted_array(hc.container)
    for low in lows {
      result.push(combine(hc.key, low))
    }
  }
  result
}

// ============ Statistics ============

///|
/// Get detailed statistics about internal structure
/// Useful for verifying container optimization
pub fn RoaringBitmap::get_stats(self : RoaringBitmap) -> RoaringStats {
  let mut array_count = 0
  let mut bitmap_count = 0
  let mut run_count = 0
  let mut total_bytes = 0
  for hc in self.containers {
    match hc.container {
      Array(arr) => {
        array_count = array_count + 1
        total_bytes = total_bytes + arr.length() * 2
      }
      Bitmap(_) => {
        bitmap_count = bitmap_count + 1
        total_bytes = total_bytes + bitmap_container_size_bytes
      }
      Run(runs) => {
        run_count = run_count + 1
        total_bytes = total_bytes + runs.length() * 4
      }
    }
  }
  let naive_bytes = if self.size == 0 { 1 } else { (self.size + 7) / 8 }
  {
    total_containers: self.containers.length(),
    array_containers: array_count,
    bitmap_containers: bitmap_count,
    run_containers: run_count,
    total_bytes_used: total_bytes,
    compression_ratio: total_bytes.to_double() / naive_bytes.to_double(),
  }
}
