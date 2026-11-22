// White-box checks for the word-level Bitmap x Bitmap fast path. The fast path
// must agree with the decode-and-optimize pipeline it replaces, both in the
// values it produces and in the representation it picks, so the portable
// output stays byte-for-byte identical. These tests reach the private
// container helpers directly; the public-API behaviour is pinned separately
// in roaring_test.mbt.

///|
fn wb_lcg(seed : Int32) -> Int32 {
  let raw = seed * 1103515245 + 12345
  if raw < 0 {
    -raw % 1000000
  } else {
    raw % 1000000
  }
}

///|
/// Random words where each bit is set with probability num/den. Returns the
/// words and the advanced seed so callers can chain fixtures.
fn random_words(
  seed : Int32,
  num : Int32,
  den : Int32,
) -> (FixedArray[UInt64], Int32) {
  let words = FixedArray::make(1024, 0UL)
  let mut s = seed
  for i = 0; i < 1024; i = i + 1 {
    let mut w = 0UL
    for b = 0; b < 64; b = b + 1 {
      s = wb_lcg(s)
      if s % den < num {
        w = w | (1UL << b)
      }
    }
    words[i] = w
  }
  (words, s)
}

///|
/// The word-level optimizer must pick the same representation AND the same
/// content as decoding to an array and running the proven optimize_container.
fn assert_same_optimization(words : FixedArray[UInt64]) -> Unit raise {
  let fast = optimize_bitmap_words(words)
  let reference = optimize_container(bitmap_to_array(words))
  assert_true(container_equals_content(fast, reference))
  match (fast, reference) {
    (Array(_), Array(_)) => ()
    (Bitmap(_), Bitmap(_)) => ()
    (Run(_), Run(_)) => ()
    _ => fail("word-level optimization picked a different representation")
  }
}

///|
test "word-level optimization matches the array pipeline on edge shapes" {
  assert_same_optimization(FixedArray::make(1024, 0UL))
  assert_same_optimization(FixedArray::make(1024, 0xFFFFFFFFFFFFFFFFUL))
  let lo = FixedArray::make(1024, 0UL)
  lo[0] = 1UL
  assert_same_optimization(lo)
  let hi = FixedArray::make(1024, 0UL)
  hi[1023] = 1UL << 63
  assert_same_optimization(hi)
  // Alternating bits: 32768 singleton runs, so Bitmap wins.
  assert_same_optimization(FixedArray::make(1024, 0x5555555555555555UL))
  // First half full, second half empty: one run of 32768, so Run wins.
  let half = FixedArray::make(1024, 0UL)
  for i = 0; i < 512; i = i + 1 {
    half[i] = 0xFFFFFFFFFFFFFFFFUL
  }
  assert_same_optimization(half)
  // A single run spanning a word boundary (bits 8..71).
  let cross = FixedArray::make(1024, 0UL)
  cross[0] = 0xFFFFFFFFFFFFFF00UL
  cross[1] = 0x00000000000000FFUL
  assert_same_optimization(cross)
}

///|
test "word-level optimization matches the array pipeline on random densities" {
  let mut seed = 4242
  // Sparse (Array), medium and dense (Bitmap), and near-full (Run) results.
  for (num, den) in [(1, 64), (1, 8), (1, 2), (3, 4), (63, 64)] {
    for _trial = 0; _trial < 4; _trial = _trial + 1 {
      let (words, next) = random_words(seed, num, den)
      seed = next
      assert_same_optimization(words)
    }
  }
}

///|
test "bitmap_run_count and bitmap_to_runs match the array pipeline" {
  let mut seed = 777
  for _trial = 0; _trial < 12; _trial = _trial + 1 {
    let (words, next) = random_words(seed, 1, 3)
    seed = next
    let reference_runs = array_to_runs(bitmap_to_array(words))
    assert_eq(bitmap_run_count(words), reference_runs.length())
    assert_true(bitmap_to_runs(words) == reference_runs)
  }
}

///|
test "run_optimize re-encodes Bitmap and Run containers without decoding" {
  // A Bitmap container holding one full run. A locally built bitmap would
  // already be a Run, so this shape only arises from a foreign producer;
  // run_optimize must turn it into a Run via the word path.
  let full = RoaringBitmap::{
    containers: [
      HighContainer::{
        key: (0 : UInt16),
        container: Bitmap(FixedArray::make(1024, 0xFFFFFFFFFFFFFFFFUL)),
        cardinality: 65536,
      },
    ],
    size: 65536L,
  }
  let optimized = full.run_optimize()
  assert_eq(optimized.get_stats().run_containers, 1)
  assert_eq(optimized.size(), 65536L)
  assert_eq(optimized.min(), Some(0U))
  assert_eq(optimized.max(), Some(65535U))
  // A dense Bitmap with many runs stays a Bitmap.
  let alternating = RoaringBitmap::{
    containers: [
      HighContainer::{
        key: (0 : UInt16),
        container: Bitmap(FixedArray::make(1024, 0x5555555555555555UL)),
        cardinality: 32768,
      },
    ],
    size: 32768L,
  }
  assert_eq(alternating.run_optimize().get_stats().bitmap_containers, 1)
  // An already-optimal Run is kept by the cost pre-check, byte for byte.
  let run_bm = RoaringBitmap::from_range(0U, 10000U)
  assert_eq(run_bm.get_stats().run_containers, 1)
  assert_eq(run_bm.run_optimize().serialize(), run_bm.serialize())
  // A foreign Run of three singletons is cheaper as an Array, so it converts.
  let sparse_run = RoaringBitmap::{
    containers: [
      HighContainer::{
        key: (0 : UInt16),
        container: Run([
          Run::{ start: (0 : UInt16), length: (0 : UInt16), },
          Run::{ start: (2 : UInt16), length: (0 : UInt16), },
          Run::{ start: (4 : UInt16), length: (0 : UInt16), },
        ]),
        cardinality: 3,
      },
    ],
    size: 3L,
  }
  let sparse_opt = sparse_run.run_optimize()
  assert_eq(sparse_opt.get_stats().array_containers, 1)
  assert_eq(sparse_opt.to_array(), [0U, 2U, 4U])
}
