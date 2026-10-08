// Cardinality-only set operations.
//
// The materializing operations (`intersect`, `union`, ...) build a whole new
// RoaringBitmap: every container is decoded, merged, re-optimized and re-boxed.
// That is the right cost when the caller wants the result set, and wasteful
// when the caller only wants to know *how many* elements it holds.
//
// `is_subset` and `jaccard_similarity` used to pay that cost, and so does any
// analytics query phrased as "how many documents match both terms". These four
// methods answer the same questions while only ever producing an `Int`.
//
// The names follow CRoaring (`roaring_bitmap_and_cardinality` and friends) so
// the API is recognizable to anyone arriving from another Roaring binding.

// ============ container-level cardinality ============

///|
/// Word-level AND of two bitmap containers. The array-decode path below is
/// correct for every container pair but pays 65536 pushes per side, so dense
/// containers get this shortcut instead: 1024 popcounts, no allocation.
fn bitmap_and_cardinality(
  w1 : FixedArray[UInt64],
  w2 : FixedArray[UInt64],
) -> Int {
  let mut count = 0
  for i = 0; i < w1.length(); i = i + 1 {
    count = count + popcount64(w1[i] & w2[i])
  }
  count
}

///|
fn bitmap_or_cardinality(
  w1 : FixedArray[UInt64],
  w2 : FixedArray[UInt64],
) -> Int {
  let mut count = 0
  for i = 0; i < w1.length(); i = i + 1 {
    count = count + popcount64(w1[i] | w2[i])
  }
  count
}

///|
fn bitmap_andnot_cardinality(
  w1 : FixedArray[UInt64],
  w2 : FixedArray[UInt64],
) -> Int {
  let mut count = 0
  for i = 0; i < w1.length(); i = i + 1 {
    count = count + popcount64(w1[i] & w2[i].lnot())
  }
  count
}

///|
fn bitmap_xor_cardinality(
  w1 : FixedArray[UInt64],
  w2 : FixedArray[UInt64],
) -> Int {
  let mut count = 0
  for i = 0; i < w1.length(); i = i + 1 {
    count = count + popcount64(w1[i] ^ w2[i])
  }
  count
}

///|
/// |A ∩ B| for two containers, counting without building the intersection.
fn container_and_cardinality(c1 : Container, c2 : Container) -> Int {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => bitmap_and_cardinality(w1, w2)
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      let mut i = 0
      let mut j = 0
      let mut count = 0
      while i < a.length() && j < b.length() {
        if a[i] == b[j] {
          count = count + 1
          i = i + 1
          j = j + 1
        } else if a[i] < b[j] {
          i = i + 1
        } else {
          j = j + 1
        }
      }
      count
    }
  }
}

///|
/// |A ∪ B| for two containers, counting without building the union.
fn container_or_cardinality(c1 : Container, c2 : Container) -> Int {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => bitmap_or_cardinality(w1, w2)
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      let mut i = 0
      let mut j = 0
      let mut count = 0
      while i < a.length() && j < b.length() {
        if a[i] == b[j] {
          count = count + 1
          i = i + 1
          j = j + 1
        } else if a[i] < b[j] {
          count = count + 1
          i = i + 1
        } else {
          count = count + 1
          j = j + 1
        }
      }
      count + (a.length() - i) + (b.length() - j)
    }
  }
}

///|
/// |A \ B| for two containers, counting without building the difference.
fn container_andnot_cardinality(c1 : Container, c2 : Container) -> Int {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => bitmap_andnot_cardinality(w1, w2)
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      let mut i = 0
      let mut j = 0
      let mut count = 0
      while i < a.length() && j < b.length() {
        if a[i] == b[j] {
          i = i + 1
          j = j + 1
        } else if a[i] < b[j] {
          count = count + 1
          i = i + 1
        } else {
          j = j + 1
        }
      }
      count + (a.length() - i)
    }
  }
}

///|
/// |A ⊕ B| for two containers, counting without building the symmetric
/// difference.
fn container_xor_cardinality(c1 : Container, c2 : Container) -> Int {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => bitmap_xor_cardinality(w1, w2)
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      let mut i = 0
      let mut j = 0
      let mut count = 0
      while i < a.length() && j < b.length() {
        if a[i] == b[j] {
          i = i + 1
          j = j + 1
        } else if a[i] < b[j] {
          count = count + 1
          i = i + 1
        } else {
          count = count + 1
          j = j + 1
        }
      }
      count + (a.length() - i) + (b.length() - j)
    }
  }
}

// ============ bitmap-level cardinality ============
//
// Each method merge-walks the two sorted container-key arrays, exactly like
// its materializing counterpart, but a matching key only contributes a count
// and a non-matching key contributes the cardinality already cached in its
// HighContainer — no container is decoded and no result bitmap is built.

///|
/// |A ∩ B| without materializing the intersection.
///
/// Equivalent to `self.intersect(other).size()`, but never allocates the
/// result. This is the query behind "how many documents match every term of
/// this conjunction", and it is what `jaccard_similarity` uses internally.
pub fn RoaringBitmap::and_cardinality(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Int {
  let mut i = 0
  let mut j = 0
  let mut count = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      i = i + 1
    } else if a.key > b.key {
      j = j + 1
    } else {
      count = count + container_and_cardinality(a.container, b.container)
      i = i + 1
      j = j + 1
    }
  }
  count
}

///|
/// |A ∪ B| without materializing the union.
///
/// Equivalent to `self.union(other).size()`. Disjoint bitmaps are answered
/// from the cached per-container cardinalities alone.
pub fn RoaringBitmap::or_cardinality(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Int {
  let mut i = 0
  let mut j = 0
  let mut count = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      count = count + a.cardinality
      i = i + 1
    } else if a.key > b.key {
      count = count + b.cardinality
      j = j + 1
    } else {
      count = count + container_or_cardinality(a.container, b.container)
      i = i + 1
      j = j + 1
    }
  }
  while i < self.containers.length() {
    count = count + self.containers[i].cardinality
    i = i + 1
  }
  while j < other.containers.length() {
    count = count + other.containers[j].cardinality
    j = j + 1
  }
  count
}

///|
/// |A \ B| without materializing the difference.
///
/// Equivalent to `self.difference(other).size()`. Zero exactly when `self`
/// is a subset of `other`, which is what `is_subset` uses internally.
pub fn RoaringBitmap::andnot_cardinality(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Int {
  let mut i = 0
  let mut j = 0
  let mut count = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      count = count + a.cardinality
      i = i + 1
    } else if a.key > b.key {
      j = j + 1
    } else {
      count = count + container_andnot_cardinality(a.container, b.container)
      i = i + 1
      j = j + 1
    }
  }
  while i < self.containers.length() {
    count = count + self.containers[i].cardinality
    i = i + 1
  }
  count
}

///|
/// |A ⊕ B| without materializing the symmetric difference.
///
/// Equivalent to `self.xor(other).size()`.
pub fn RoaringBitmap::xor_cardinality(
  self : RoaringBitmap,
  other : RoaringBitmap,
) -> Int {
  let mut i = 0
  let mut j = 0
  let mut count = 0
  while i < self.containers.length() && j < other.containers.length() {
    let a = self.containers[i]
    let b = other.containers[j]
    if a.key < b.key {
      count = count + a.cardinality
      i = i + 1
    } else if a.key > b.key {
      count = count + b.cardinality
      j = j + 1
    } else {
      count = count + container_xor_cardinality(a.container, b.container)
      i = i + 1
      j = j + 1
    }
  }
  while i < self.containers.length() {
    count = count + self.containers[i].cardinality
    i = i + 1
  }
  while j < other.containers.length() {
    count = count + other.containers[j].cardinality
    j = j + 1
  }
  count
}
