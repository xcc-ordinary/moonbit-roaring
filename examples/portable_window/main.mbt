// A time-window handoff: build a consecutive event-ID window, serialize it
// using the Roaring portable format, and validate what another implementation
// will receive.
//
// Run with: moon run examples/portable_window

///|
fn main {
  let event_ids = @roaring.RoaringBitmap::from_range(1_000U, 5_000U)
  let stats = event_ids.get_stats()
  let wire_bytes = event_ids.serialize()
  let received = match @roaring.RoaringBitmap::deserialize(wire_bytes) {
    Ok(bitmap) => bitmap
    Err(error) => {
      println("portable handoff failed: \{error}")
      panic()
    }
  }

  println("event IDs: \{event_ids.size()}")
  println("run containers: \{stats.run_containers}")
  println("portable bytes: \{wire_bytes.length()}")
  println("receiver matches sender: \{received.equals(event_ids)}")
}
