// Core data types for RoaringBitmap implementation
// Based on official RoaringBitmap specification

///|
/// Container size thresholds
pub let array_container_max_size : Int32 = 4096

///|
pub let bitmap_container_size_bytes : Int32 = 8192 // 2^16 bits / 8 = 8KB

///|
/// Descriptive, not enforced: the shortest run-length-encoded sequence worth
/// storing as a Run. No code path reads this constant — `optimize_container`
/// reaches the same conclusion by cost, because a run of one value costs 4
/// bytes against an array element's 2. It is kept as published 0.1.0 API so
/// that callers referring to it do not break; read `optimize_container` for
/// the rule that actually governs container selection.
pub let run_container_min_run_length : Int32 = 2

///|
/// Container types - the core of Roaring's compression strategy
priv enum Container {
  /// Sparse data: sorted array of UInt16 values (< 4096 elements)
  Array(Array[UInt16])
  /// Dense data: 8KB bitmap (≥ 4096 elements)
  /// Represented as 1024 × UInt64 = 65536 bits
  Bitmap(FixedArray[UInt64])
  /// Consecutive ranges: run-length encoded
  /// Each run is [start, length] where length = actual_count - 1
  Run(Array[Run])
} derive(Eq)

///|
/// A run represents a consecutive range [start, start+length]
pub struct Run {
  start : UInt16
  length : UInt16 // stored as (count - 1) to match official format
} derive(Eq, Debug)

///|
/// `derive` promotes trait methods onto the type; declaring them here makes
/// that promotion explicit instead of relying on the deprecated implicit form.
pub extend Run with Eq::{equal, not_equal}

///|
pub extend Run with Debug::{to_repr}

///|
/// High-level container: associates a 16-bit key with a container
/// RoaringBitmap partitions 32-bit integers into:
/// - high 16 bits → key (bucket index)
/// - low 16 bits → stored in container
struct HighContainer {
  key : UInt16
  container : Container
  cardinality : Int32 // cached element count for this container
} derive(Eq)

///|
pub extend HighContainer with Eq::{equal, not_equal}

///|
/// The main RoaringBitmap structure
pub struct RoaringBitmap {
  containers : Array[HighContainer] // sorted by key
  size : Int64 // total cardinality across all containers
} derive(Eq)

///|
pub extend RoaringBitmap with Eq::{equal, not_equal}

///|
/// Error types
pub enum RoaringError {
  DeserializationError(String)
} derive(Eq, Debug)

///|
pub extend RoaringError with Eq::{equal, not_equal}

///|
pub extend RoaringError with Debug::{to_repr}

///|
pub impl Show for RoaringError with fn output(self, logger) {
  match self {
    DeserializationError(msg) =>
      logger.write_string("DeserializationError: " + msg)
  }
}

///|
pub extend RoaringError with Show::{to_string, output}

///|
/// Binary search result for sorted arrays/container lists
priv enum SearchResult {
  Found(Int32)
  NotFound(Int32)
}

///|
/// Statistics for debugging and optimization verification
pub struct RoaringStats {
  total_containers : Int32
  array_containers : Int32
  bitmap_containers : Int32
  run_containers : Int32
  total_bytes_used : Int32
  compression_ratio : Double // vs. naive bitmap
} derive(Debug)

///|
pub extend RoaringStats with Debug::{to_repr}
