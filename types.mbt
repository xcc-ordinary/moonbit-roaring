// Core data types for RoaringBitmap implementation
// Based on official RoaringBitmap specification

///|
/// Container size thresholds
pub let array_container_max_size : Int = 4096

///|
pub let bitmap_container_size_bytes : Int = 8192 // 2^16 bits / 8 = 8KB

///|
pub let run_container_min_run_length : Int = 2 // minimum consecutive elements to form a run

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
/// High-level container: associates a 16-bit key with a container
/// RoaringBitmap partitions 32-bit integers into:
/// - high 16 bits → key (bucket index)
/// - low 16 bits → stored in container
struct HighContainer {
  key : UInt16
  container : Container
  cardinality : Int // cached element count for this container
} derive(Eq)

///|
/// The main RoaringBitmap structure
pub struct RoaringBitmap {
  containers : Array[HighContainer] // sorted by key
  size : Int // total cardinality across all containers
} derive(Eq)

///|
/// Error types
pub enum RoaringError {
  InvalidInput(String)
  SerializationError(String)
  DeserializationError(String)
} derive(Eq, Debug)

///|
impl Show for RoaringError with fn output(self, logger) {
  match self {
    InvalidInput(msg) => logger.write_string("InvalidInput: " + msg)
    SerializationError(msg) => logger.write_string("SerializationError: " + msg)
    DeserializationError(msg) =>
      logger.write_string("DeserializationError: " + msg)
  }
}

///|
/// Binary search result for sorted arrays/container lists
priv enum SearchResult {
  Found(Int)
  NotFound(Int)
}

///|
/// Statistics for debugging and optimization verification
pub struct RoaringStats {
  total_containers : Int
  array_containers : Int
  bitmap_containers : Int
  run_containers : Int
  total_bytes_used : Int
  compression_ratio : Double // vs. naive bitmap
} derive(Debug)
