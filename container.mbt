// Core container operations: encode/decode, cost-based optimization, and
// container-level set operations.
//
// Design decision: every mutation (add/remove/union/intersect/difference/xor)
// decodes its operand(s) to a sorted, de-duplicated Array[UInt16], performs the
// operation on that array, then calls `optimize_container` to re-pick the
// cheapest representation. This is what makes Run containers a real, reachable
// outcome instead of dead code: `optimize_container` is on every mutation path,
// not an unused helper. The tradeoff is O(n) work per mutation instead of
// specialized per-type-pair fast paths (e.g. word-level bitmap union); that is
// an intentional correctness-first choice for this project's timeline.

// ============ UInt32 <-> (high16, low16) ============

///|
fn extract_high(value : UInt) -> UInt16 {
  (value >> 16).reinterpret_as_int().to_uint16()
}

///|
fn extract_low(value : UInt) -> UInt16 {
  let low_bits = value % 65536U
  low_bits.reinterpret_as_int().to_uint16()
}

///|
fn combine(high : UInt16, low : UInt16) -> UInt {
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
fn run_cardinality(runs : Array[Run]) -> Int {
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
    let mut bit = 0
    while word != 0UL {
      if (word & 1UL) != 0UL {
        result.push((word_idx * 64 + bit).to_uint16())
      }
      word = word >> 1
      bit = bit + 1
    }
  }
  result
}

///|
fn popcount64(word : UInt64) -> Int {
  let mut w = word
  let mut count = 0
  while w != 0UL {
    w = w & (w - 1UL)
    count = count + 1
  }
  count
}

///|
fn bitmap_cardinality(words : FixedArray[UInt64]) -> Int {
  let mut total = 0
  for word_idx = 0; word_idx < words.length(); word_idx = word_idx + 1 {
    total = total + popcount64(words[word_idx])
  }
  total
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
fn container_cardinality(c : Container) -> Int {
  match c {
    Array(arr) => arr.length()
    Bitmap(bm) => bitmap_cardinality(bm)
    Run(runs) => run_cardinality(runs)
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
      let mut found = false
      let v = value.to_int()
      for r in runs {
        let start = r.start.to_int()
        let end = start + r.length.to_int()
        if v >= start && v <= end {
          found = true
        }
      }
      found
    }
  }
}

///|
fn container_min(c : Container) -> UInt16? {
  match c {
    Array(arr) => if arr.length() == 0 { None } else { Some(arr[0]) }
    Bitmap(bm) => {
      let arr = bitmap_to_array(bm)
      if arr.length() == 0 {
        None
      } else {
        Some(arr[0])
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
      let arr = bitmap_to_array(bm)
      if arr.length() == 0 {
        None
      } else {
        Some(arr[arr.length() - 1])
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
  let array_cost = arr.length() * 2
  let bitmap_cost = bitmap_container_size_bytes
  let run_cost = runs.length() * 4
  if run_cost <= array_cost && run_cost <= bitmap_cost {
    Run(runs)
  } else if array_cost <= bitmap_cost {
    Array(arr)
  } else {
    Bitmap(array_to_bitmap(arr))
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
  let a = container_to_sorted_array(c1)
  let b = container_to_sorted_array(c2)
  optimize_container(sorted_union(a, b))
}

///|
fn container_intersect(c1 : Container, c2 : Container) -> Container {
  let a = container_to_sorted_array(c1)
  let b = container_to_sorted_array(c2)
  optimize_container(sorted_intersect(a, b))
}

///|
fn container_difference(c1 : Container, c2 : Container) -> Container {
  let a = container_to_sorted_array(c1)
  let b = container_to_sorted_array(c2)
  optimize_container(sorted_difference(a, b))
}

///|
fn container_xor(c1 : Container, c2 : Container) -> Container {
  let a = container_to_sorted_array(c1)
  let b = container_to_sorted_array(c2)
  optimize_container(sorted_xor(a, b))
}
