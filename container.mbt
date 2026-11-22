// Core container operations: encode/decode, cost-based optimization, and
// container-level set operations.
//
// Design decision: single-value mutations (add/remove) and mixed-type set
// operations decode their operand(s) to a sorted, de-duplicated Array[UInt16],
// perform the operation on that array, then call `optimize_container` to
// re-pick the cheapest representation. This is what makes Run containers a
// real, reachable outcome instead of dead code: `optimize_container` is on
// every mutation path, not an unused helper.
//
// The four set operations (union/intersect/difference/xor) take a word-level
// fast path when both operands are Bitmap containers: 1024 word operations
// produce the result, and `optimize_bitmap_words` re-picks the cheapest
// representation from the words alone, decoding only when the result is
// sparse enough to be an Array. This avoids materializing and merging two
// 65536-element arrays for the dense case, while staying byte-for-byte
// identical to the decode-and-optimize pipeline it replaces.

// ============ UInt32 <-> (high16, low16) ============

///|
fn extract_high(value : UInt32) -> UInt16 {
  (value >> 16).reinterpret_as_int().to_uint16()
}

///|
fn extract_low(value : UInt32) -> UInt16 {
  let low_bits = value % 65536U
  low_bits.reinterpret_as_int().to_uint16()
}

///|
fn combine(high : UInt16, low : UInt16) -> UInt32 {
  let high_bits = high.to_int().reinterpret_as_uint() << 16
  let low_bits = low.to_int().reinterpret_as_uint()
  high_bits | low_bits
}

// ============ Sorted UInt16 array primitives ============

///|
fn binary_search_u16(arr : Array[UInt16], value : UInt16) -> SearchResult {
  let mut left = 0
  let mut right = arr.length()
  while left < right {
    let mid = (left + right) / 2
    if arr[mid] == value {
      return Found(mid)
    } else if arr[mid] < value {
      left = mid + 1
    } else {
      right = mid
    }
  }
  NotFound(left)
}

///|
fn sorted_insert(arr : Array[UInt16], value : UInt16) -> Array[UInt16] {
  match binary_search_u16(arr, value) {
    Found(_) => arr
    NotFound(pos) => {
      let result = []
      for i = 0; i < pos; i = i + 1 {
        result.push(arr[i])
      }
      result.push(value)
      for i = pos; i < arr.length(); i = i + 1 {
        result.push(arr[i])
      }
      result
    }
  }
}

///|
fn sorted_remove(arr : Array[UInt16], value : UInt16) -> Array[UInt16] {
  match binary_search_u16(arr, value) {
    NotFound(_) => arr
    Found(pos) => {
      let result = []
      for i = 0; i < arr.length(); i = i + 1 {
        if i != pos {
          result.push(arr[i])
        }
      }
      result
    }
  }
}

///|
fn sorted_union(a : Array[UInt16], b : Array[UInt16]) -> Array[UInt16] {
  let result = []
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    if a[i] == b[j] {
      result.push(a[i])
      i = i + 1
      j = j + 1
    } else if a[i] < b[j] {
      result.push(a[i])
      i = i + 1
    } else {
      result.push(b[j])
      j = j + 1
    }
  }
  while i < a.length() {
    result.push(a[i])
    i = i + 1
  }
  while j < b.length() {
    result.push(b[j])
    j = j + 1
  }
  result
}

///|
fn sorted_intersect(a : Array[UInt16], b : Array[UInt16]) -> Array[UInt16] {
  let result = []
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    if a[i] == b[j] {
      result.push(a[i])
      i = i + 1
      j = j + 1
    } else if a[i] < b[j] {
      i = i + 1
    } else {
      j = j + 1
    }
  }
  result
}

///|
fn sorted_difference(a : Array[UInt16], b : Array[UInt16]) -> Array[UInt16] {
  let result = []
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    if a[i] == b[j] {
      i = i + 1
      j = j + 1
    } else if a[i] < b[j] {
      result.push(a[i])
      i = i + 1
    } else {
      j = j + 1
    }
  }
  while i < a.length() {
    result.push(a[i])
    i = i + 1
  }
  result
}

///|
fn sorted_xor(a : Array[UInt16], b : Array[UInt16]) -> Array[UInt16] {
  let result = []
  let mut i = 0
  let mut j = 0
  while i < a.length() && j < b.length() {
    if a[i] == b[j] {
      i = i + 1
      j = j + 1
    } else if a[i] < b[j] {
      result.push(a[i])
      i = i + 1
    } else {
      result.push(b[j])
      j = j + 1
    }
  }
  while i < a.length() {
    result.push(a[i])
    i = i + 1
  }
  while j < b.length() {
    result.push(b[j])
    j = j + 1
  }
  result
}

// ============ Run-length encode/decode ============

///|
fn array_to_runs(arr : Array[UInt16]) -> Array[Run] {
  let runs = []
  if arr.length() == 0 {
    return runs
  }
  let mut run_start = arr[0]
  let mut run_end = arr[0]
  for i = 1; i < arr.length(); i = i + 1 {
    let v = arr[i]
    if v.to_int() == run_end.to_int() + 1 {
      run_end = v
    } else {
      runs.push(Run::{
        start: run_start,
        length: (run_end.to_int() - run_start.to_int()).to_uint16(),
      })
      run_start = v
      run_end = v
    }
  }
  runs.push(Run::{
    start: run_start,
    length: (run_end.to_int() - run_start.to_int()).to_uint16(),
  })
  runs
}

///|
fn runs_to_array(runs : Array[Run]) -> Array[UInt16] {
  let result = []
  for r in runs {
    let start = r.start.to_int()
    let len = r.length.to_int()
    for i = 0; i <= len; i = i + 1 {
      result.push((start + i).to_uint16())
    }
  }
  result
}

///|
fn run_cardinality(runs : Array[Run]) -> Int32 {
  let mut total = 0
  for r in runs {
    total = total + r.length.to_int() + 1
  }
  total
}

// ============ Bitmap encode/decode (1024 x UInt64 = 65536 bits) ============

///|
fn array_to_bitmap(arr : Array[UInt16]) -> FixedArray[UInt64] {
  let words = FixedArray::make(1024, 0UL)
  for v in arr {
    let idx = v.to_int() / 64
    let bit = v.to_int() % 64
    words[idx] = words[idx] | (1UL << bit)
  }
  words
}

///|
fn bitmap_to_array(words : FixedArray[UInt64]) -> Array[UInt16] {
  let result = []
  for word_idx = 0; word_idx < words.length(); word_idx = word_idx + 1 {
    let mut word = words[word_idx]
    let base = word_idx * 64
    // Walk only the set bits (Kernighan), not all 64 positions: a word with
    // one set bit costs one iteration instead of sixty-four. Same pattern as
    // the complement paths' emit_set_bits.
    while word != 0UL {
      let bit = lowest_set_bit(word)
      result.push((base + bit).to_uint16())
      word = word & (word - 1UL)
    }
  }
  result
}

///|
fn popcount64(word : UInt64) -> Int32 {
  let mut w = word
  let mut count = 0
  while w != 0UL {
    w = w & (w - 1UL)
    count = count + 1
  }
  count
}

///|
fn bitmap_cardinality(words : FixedArray[UInt64]) -> Int32 {
  let mut total = 0
  for word_idx = 0; word_idx < words.length(); word_idx = word_idx + 1 {
    total = total + popcount64(words[word_idx])
  }
  total
}

///|
/// Number of runs in a bitmap, counted a word at a time: a run starts at each
/// set bit whose predecessor is clear, and the predecessor of a word's bit 0
/// is the previous word's bit 63. O(1024 + runs) with no decode.
fn bitmap_run_count(words : FixedArray[UInt64]) -> Int32 {
  let mut count = 0
  let mut prev_bit63 = 0UL
  for i = 0; i < words.length(); i = i + 1 {
    let w = words[i]
    let starts = w & ((w << 1) | prev_bit63).lnot()
    count = count + popcount64(starts)
    prev_bit63 = w >> 63
  }
  count
}

///|
/// Extract the runs of a bitmap directly from its words, O(1024 + runs). A run
/// starts where a set bit's predecessor is clear and ends where a set bit's
/// successor is clear; the two boundary sets have equal size and pair up in
/// ascending order. Cross-word boundaries are handled by feeding each word its
/// neighbour's edge bit, so a run spanning several words is emitted once.
fn bitmap_to_runs(words : FixedArray[UInt64]) -> Array[Run] {
  let starts = []
  let ends = []
  for i = 0; i < words.length(); i = i + 1 {
    let w = words[i]
    if w == 0UL {
      continue
    }
    let prev = if i > 0 { words[i - 1] >> 63 } else { 0UL }
    let next = if i + 1 < words.length() { words[i + 1] & 1UL } else { 0UL }
    let base = i * 64
    let mut s = w & ((w << 1) | prev).lnot()
    while s != 0UL {
      starts.push(base + lowest_set_bit(s))
      s = s & (s - 1UL)
    }
    let mut e = w & ((w >> 1) | (next << 63)).lnot()
    while e != 0UL {
      ends.push(base + lowest_set_bit(e))
      e = e & (e - 1UL)
    }
  }
  let runs = []
  for k = 0; k < starts.length(); k = k + 1 {
    runs.push(Run::{
      start: starts[k].to_uint16(),
      length: (ends[k] - starts[k]).to_uint16(),
    })
  }
  runs
}

// ============ Decode any container to a sorted array ============

///|
fn container_to_sorted_array(c : Container) -> Array[UInt16] {
  match c {
    Array(arr) => arr
    Bitmap(bm) => bitmap_to_array(bm)
    Run(runs) => runs_to_array(runs)
  }
}

///|
fn container_cardinality(c : Container) -> Int32 {
  match c {
    Array(arr) => arr.length()
    Bitmap(bm) => bitmap_cardinality(bm)
    Run(runs) => run_cardinality(runs)
  }
}

///|
/// Index of the lowest set bit in a non-zero word, or -1 if the word is zero.
///
/// Binary search rather than a shift loop. This runs once per emitted bit in
/// the complement paths, where a linear scan would cost more than the 64-bit
/// loop it was meant to replace.
fn lowest_set_bit(word : UInt64) -> Int32 {
  if word == 0UL {
    -1
  } else {
    let mut n = 0
    let mut w = word
    if (w & 0xFFFFFFFFUL) == 0UL {
      n = n + 32
      w = w >> 32
    }
    if (w & 0xFFFFUL) == 0UL {
      n = n + 16
      w = w >> 16
    }
    if (w & 0xFFUL) == 0UL {
      n = n + 8
      w = w >> 8
    }
    if (w & 0xFUL) == 0UL {
      n = n + 4
      w = w >> 4
    }
    if (w & 0x3UL) == 0UL {
      n = n + 2
      w = w >> 2
    }
    if (w & 0x1UL) == 0UL {
      n = n + 1
    }
    n
  }
}

///|
/// Index of the highest set bit in a non-zero word, or -1 if the word is zero.
fn highest_set_bit(word : UInt64) -> Int32 {
  if word == 0UL {
    -1
  } else {
    let mut w = word
    let mut bit = 63
    while (w & (1UL << 63)) == 0UL {
      w = w << 1
      bit = bit - 1
    }
    bit
  }
}

///|
fn container_contains(c : Container, value : UInt16) -> Bool {
  match c {
    Array(arr) =>
      match binary_search_u16(arr, value) {
        Found(_) => true
        NotFound(_) => false
      }
    Bitmap(bm) => {
      let idx = value.to_int() / 64
      let bit = value.to_int() % 64
      (bm[idx] & (1UL << bit)) != 0UL
    }
    Run(runs) => {
      // Runs are sorted and disjoint, so a binary search finds the only run
      // that could contain the value instead of scanning all of them.
      let v = value.to_int()
      let mut left = 0
      let mut right = runs.length()
      while left < right {
        let mid = (left + right) / 2
        let start = runs[mid].start.to_int()
        if v < start {
          right = mid
        } else if v > start + runs[mid].length.to_int() {
          left = mid + 1
        } else {
          return true
        }
      }
      false
    }
  }
}

///|
/// Whether two containers hold exactly the same values. Same-type pairs are
/// compared structurally, which is O(compressed size); only containers stored
/// under different representations are decoded.
fn container_equals_content(a : Container, b : Container) -> Bool {
  match (a, b) {
    (Array(x), Array(y)) => x == y
    (Bitmap(x), Bitmap(y)) => x == y
    (Run(x), Run(y)) => x == y
    _ => container_to_sorted_array(a) == container_to_sorted_array(b)
  }
}

///|
/// Whether every value of `a` is also present in `b`. Deliberately a
/// membership walk rather than a cardinality comparison: a count-based test
/// would need `|A \ B| == 0`, and that total can overflow an `Int`.
///
/// Two Bitmap containers are compared a word at a time — 1024 ANDs with no
/// decode and no allocation, where the generic path below would decode both
/// sides into 65536-element arrays first. Measured at roughly 27x on a
/// four-Bitmap fixture.
fn container_is_subset(a : Container, b : Container) -> Bool {
  match (a, b) {
    (Bitmap(w1), Bitmap(w2)) => {
      for i = 0; i < w1.length(); i = i + 1 {
        // Any bit set in a but clear in b means a is not a subset of b.
        if (w1[i] & w2[i].lnot()) != 0UL {
          return false
        }
      }
      true
    }
    _ => {
      for v in container_to_sorted_array(a) {
        if !container_contains(b, v) {
          return false
        }
      }
      true
    }
  }
}

///|
fn container_min(c : Container) -> UInt16? {
  match c {
    Array(arr) => if arr.length() == 0 { None } else { Some(arr[0]) }
    // Scanning for the first non-zero word is O(1024) with no allocation,
    // where decoding to an array is O(65536) plus a 65536-element array.
    Bitmap(bm) => {
      let mut i = 0
      while i < bm.length() && bm[i] == 0UL {
        i = i + 1
      }
      if i >= bm.length() {
        None
      } else {
        Some((i * 64 + lowest_set_bit(bm[i])).to_uint16())
      }
    }
    Run(runs) => if runs.length() == 0 { None } else { Some(runs[0].start) }
  }
}

///|
fn container_max(c : Container) -> UInt16? {
  match c {
    Array(arr) =>
      if arr.length() == 0 {
        None
      } else {
        Some(arr[arr.length() - 1])
      }
    Bitmap(bm) => {
      let mut i = bm.length() - 1
      while i >= 0 && bm[i] == 0UL {
        i = i - 1
      }
      if i < 0 {
        None
      } else {
        Some((i * 64 + highest_set_bit(bm[i])).to_uint16())
      }
    }
    Run(runs) =>
      if runs.length() == 0 {
        None
      } else {
        let last = runs[runs.length() - 1]
        Some((last.start.to_int() + last.length.to_int()).to_uint16())
      }
  }
}

// ============ THE KEY HOOK: cost-based container selection ============
//
// Given a sorted, de-duplicated array of values, choose whichever container
// representation is smallest in bytes. This function sits on every mutation
// path below, which is exactly the wiring that was missing from the existing
// ecosystem implementation (Run containers were defined as a variant but
// never selected by any real code path).

///|
fn optimize_container(arr : Array[UInt16]) -> Container {
  if arr.length() == 0 {
    return Array([])
  }
  let runs = array_to_runs(arr)
  // These three figures must match `container_byte_size`, which is what
  // serialization actually writes. The Run cost used to omit the two-byte
  // run-count header, so at an exact tie the encoder picked Run and then
  // emitted two bytes more than the Array or Bitmap it was compared against.
  let array_cost = arr.length() * 2
  let bitmap_cost = bitmap_container_size_bytes
  let run_cost = 2 + 4 * runs.length()
  if run_cost <= array_cost && run_cost <= bitmap_cost {
    Run(runs)
  } else if array_cost <= bitmap_cost {
    Array(arr)
  } else {
    Bitmap(array_to_bitmap(arr))
  }
}

///|
/// Pick the cheapest representation for a bitmap result without decoding it to
/// a value array first. Mirrors `optimize_container`'s cost model and tie
/// breaking exactly (Run, then Array, then Bitmap), so the two agree byte for
/// byte on the portable output. Only the Array case decodes; a Run result is
/// read straight from the words and a Bitmap result is wrapped as is.
fn optimize_bitmap_words(words : FixedArray[UInt64]) -> Container {
  let card = bitmap_cardinality(words)
  if card == 0 {
    return Array([])
  }
  let nruns = bitmap_run_count(words)
  let array_cost = card * 2
  let bitmap_cost = bitmap_container_size_bytes
  let run_cost = 2 + 4 * nruns
  if run_cost <= array_cost && run_cost <= bitmap_cost {
    Run(bitmap_to_runs(words))
  } else if array_cost <= bitmap_cost {
    Array(bitmap_to_array(words))
  } else {
    Bitmap(words)
  }
}

// ============ Container-level mutation, always re-optimized ============

///|
fn container_from_sorted_array(arr : Array[UInt16]) -> Container {
  optimize_container(arr)
}

///|
fn container_add(c : Container, value : UInt16) -> Container {
  let arr = container_to_sorted_array(c)
  optimize_container(sorted_insert(arr, value))
}

///|
fn container_remove(c : Container, value : UInt16) -> Container {
  let arr = container_to_sorted_array(c)
  optimize_container(sorted_remove(arr, value))
}

///|
fn container_union(c1 : Container, c2 : Container) -> Container {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => {
      let words = FixedArray::make(1024, 0UL)
      for i = 0; i < w1.length(); i = i + 1 {
        words[i] = w1[i] | w2[i]
      }
      optimize_bitmap_words(words)
    }
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      optimize_container(sorted_union(a, b))
    }
  }
}

///|
fn container_intersect(c1 : Container, c2 : Container) -> Container {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => {
      let words = FixedArray::make(1024, 0UL)
      for i = 0; i < w1.length(); i = i + 1 {
        words[i] = w1[i] & w2[i]
      }
      optimize_bitmap_words(words)
    }
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      optimize_container(sorted_intersect(a, b))
    }
  }
}

///|
fn container_difference(c1 : Container, c2 : Container) -> Container {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => {
      let words = FixedArray::make(1024, 0UL)
      for i = 0; i < w1.length(); i = i + 1 {
        words[i] = w1[i] & w2[i].lnot()
      }
      optimize_bitmap_words(words)
    }
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      optimize_container(sorted_difference(a, b))
    }
  }
}

///|
fn container_xor(c1 : Container, c2 : Container) -> Container {
  match (c1, c2) {
    (Bitmap(w1), Bitmap(w2)) => {
      let words = FixedArray::make(1024, 0UL)
      for i = 0; i < w1.length(); i = i + 1 {
        words[i] = w1[i] ^ w2[i]
      }
      optimize_bitmap_words(words)
    }
    _ => {
      let a = container_to_sorted_array(c1)
      let b = container_to_sorted_array(c2)
      optimize_container(sorted_xor(a, b))
    }
  }
}
