// Public API for RoaringBitmap
// Core operations that will hook into container auto-optimization

// ============ Construction ============

/// Create an empty RoaringBitmap
pub fn RoaringBitmap::new() -> RoaringBitmap {
  { containers: [], size: 0 }
}

/// Create from a single value
pub fn RoaringBitmap::singleton(_value : UInt) -> RoaringBitmap {
  // TODO: implement
  RoaringBitmap::new()
}

/// Create from an array of values
pub fn RoaringBitmap::from_array(_values : Array[UInt]) -> RoaringBitmap {
  // TODO: implement with batch optimization
  RoaringBitmap::new()
}

// ============ Basic Operations ============

/// Add a single element
/// Auto-optimizes container type based on density
pub fn RoaringBitmap::add(self : RoaringBitmap, _value : UInt) -> RoaringBitmap {
  // TODO: implement with container auto-upgrade
  self
}

/// Add multiple elements efficiently
/// Detects consecutive runs and creates RunContainer when beneficial
pub fn RoaringBitmap::add_many(self : RoaringBitmap, _values : Array[UInt]) -> RoaringBitmap {
  // TODO: implement with run-length detection
  self
}

/// Remove a single element
pub fn RoaringBitmap::remove(self : RoaringBitmap, _value : UInt) -> RoaringBitmap {
  // TODO: implement with container auto-downgrade
  self
}

/// Check if element exists
pub fn RoaringBitmap::contains(self : RoaringBitmap, _value : UInt) -> Bool {
  ignore(self)
  // TODO: implement
  false
}

/// Get cardinality (number of elements)
pub fn RoaringBitmap::size(self : RoaringBitmap) -> Int {
  self.size
}

/// Check if empty
pub fn RoaringBitmap::is_empty(self : RoaringBitmap) -> Bool {
  self.size == 0
}

// ============ Set Operations ============

/// Union: A ∪ B
pub fn RoaringBitmap::union(self : RoaringBitmap, _other : RoaringBitmap) -> RoaringBitmap {
  // TODO: implement with container merging and auto-optimization
  self
}

/// Intersection: A ∩ B
pub fn RoaringBitmap::intersect(self : RoaringBitmap, _other : RoaringBitmap) -> RoaringBitmap {
  // TODO: implement
  self
}

/// Difference: A \ B
pub fn RoaringBitmap::difference(self : RoaringBitmap, _other : RoaringBitmap) -> RoaringBitmap {
  // TODO: implement
  self
}

/// Symmetric difference: A ⊕ B
pub fn RoaringBitmap::xor(self : RoaringBitmap, _other : RoaringBitmap) -> RoaringBitmap {
  // TODO: implement
  self
}

// ============ Serialization (CRoaring-compatible) ============

/// Serialize to portable binary format (compatible with CRoaring)
/// portable=true: cross-language format (slower but universal)
/// portable=false: native format (faster but MoonBit-only)
pub fn RoaringBitmap::serialize(self : RoaringBitmap, portable : Bool) -> Bytes {
  ignore(self)
  ignore(portable)
  // TODO: implement official portable format from RoaringFormatSpec
  Bytes::new(0)
}

/// Deserialize from portable binary format
pub fn RoaringBitmap::deserialize(_data : Bytes, _portable : Bool) -> Result[RoaringBitmap, RoaringError] {
  // TODO: implement with error handling
  Err(RoaringError::DeserializationError("not implemented"))
}

// ============ Conversion ============

/// Convert to sorted array
pub fn RoaringBitmap::to_array(self : RoaringBitmap) -> Array[UInt] {
  ignore(self)
  // TODO: implement
  []
}

/// Create iterator
pub fn RoaringBitmap::iter(self : RoaringBitmap) -> Iter[UInt] {
  ignore(self)
  // TODO: implement efficient container-aware iteration
  Iter::empty()
}

// ============ Statistics ============

/// Get detailed statistics about internal structure
/// Useful for verifying container optimization
pub fn RoaringBitmap::get_stats(self : RoaringBitmap) -> RoaringStats {
  ignore(self)
  // TODO: implement
  {
    total_containers: 0,
    array_containers: 0,
    bitmap_containers: 0,
    run_containers: 0,
    total_bytes_used: 0,
    compression_ratio: 0.0
  }
}

// ============ Internal Helpers (will be implemented) ============

// Container operations (to be implemented in container.mbt)
// - container_add(Container, UInt16) -> Container
// - container_remove(Container, UInt16) -> Container
// - container_union(Container, Container) -> Container
// - container_intersect(Container, Container) -> Container
// - optimize_container(Container) -> Container  // THIS IS THE KEY HOOK

// Run-length detection heuristic (to be implemented in run_optimizer.mbt)
// - detect_runs(Array[UInt16]) -> Bool
// - should_convert_to_run(Container) -> Bool
// - array_to_run(Array[UInt16]) -> Array[Run]
