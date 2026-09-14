// Runnable example: a toy search-engine inverted index using RoaringBitmap
// for postings lists. Demonstrates the three things this library is built
// to do well:
//   1. Fast set intersection/union for multi-term queries
//   2. Automatic compression (a term that appears in a long consecutive
//      run of document IDs collapses into a handful of bytes)
//   3. Portable serialization, so the index built here could be written to
//      disk or shipped to a service in another language
//
// Run with: moon run examples/inverted_index

fn build_postings(term : String, doc_ids : Array[UInt]) -> (String, @roaring.RoaringBitmap) {
  (term, @roaring.RoaringBitmap::from_array(doc_ids))
}

fn main {
  // Pretend corpus: doc IDs 0..999. "machine" and "learning" co-occur in a
  // consecutive block of documents (e.g. a single imported dataset), while
  // "rust" is scattered across the corpus.
  let machine_docs = []
  for i = 100; i < 400; i = i + 1 {
    machine_docs.push(i.reinterpret_as_uint())
  }
  let learning_docs = []
  for i = 250; i < 500; i = i + 1 {
    learning_docs.push(i.reinterpret_as_uint())
  }
  let rust_docs = [5U, 42U, 250U, 300U, 999U]

  let (_, machine) = build_postings("machine", machine_docs)
  let (_, learning) = build_postings("learning", learning_docs)
  let (_, rust) = build_postings("rust", rust_docs)

  println("Postings list sizes:")
  println("  machine:  \{machine.size()} docs")
  println("  learning: \{learning.size()} docs")
  println("  rust:     \{rust.size()} docs")
  println("")

  // Query: "machine" AND "learning" -> documents containing both terms.
  let machine_and_learning = machine.intersect(learning)
  println("\"machine\" AND \"learning\": \{machine_and_learning.size()} docs")
  println("  range: [\{machine_and_learning.min().unwrap()}, \{machine_and_learning.max().unwrap()}]")

  // Query: "machine" AND "learning" AND "rust" -> narrow further.
  let all_three = machine_and_learning.intersect(rust)
  println("\"machine\" AND \"learning\" AND \"rust\": \{all_three.size()} docs")
  let ids = all_three.to_array().map(fn(v) { v.to_string() })
  println("  doc IDs: [\{ids.join(", ")}]")
  println("")

  // Query: "machine" OR "rust" -> documents containing either term.
  let machine_or_rust = machine.union(rust)
  println("\"machine\" OR \"rust\": \{machine_or_rust.size()} docs")
  println("")

  // Compression check: the "machine" postings list is 300 consecutive
  // document IDs. Confirm it collapsed into a Run container instead of
  // paying for an 8KB bitmap or a 600-byte array.
  let stats = machine.get_stats()
  println("\"machine\" postings internal representation:")
  println("  containers: \{stats.total_containers} (array=\{stats.array_containers}, bitmap=\{stats.bitmap_containers}, run=\{stats.run_containers})")
  println("  bytes used: \{stats.total_bytes_used} (vs. \{machine.size() * 2} bytes as a plain UInt16 array)")
  println("")

  // Portability check: serialize to the CRoaring-compatible format and
  // read it back. In a real system this is what lets a Rust or Go service
  // consume the same postings list this MoonBit indexer produced.
  let bytes = machine.serialize(true)
  println("Serialized \"machine\" postings to \{bytes.length()} bytes (portable format)")
  let restored = match @roaring.RoaringBitmap::deserialize(bytes, true) {
    Ok(r) => r
    Err(e) => {
      println("deserialize failed: \{e}")
      panic()
    }
  }
  println("Round-trip check: \{restored.equals(machine)}")
}
