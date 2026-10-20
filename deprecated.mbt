// Deprecated API surface.
//
// Kept per AGENTS.md ("keep deprecated blocks in file called
// `deprecated.mbt`"). Everything here is still exported so that 0.1.0 callers
// do not break, but nothing in this package reads it, and new code should not
// either.

///|
/// Deprecated: retained for 0.1.0 API compatibility. Read by no code path.
///
/// The shortest run-length-encoded sequence worth storing as a Run.
/// `optimize_container` reaches the same conclusion by cost instead, because a
/// run of one value costs 4 bytes against an array element's 2, so this
/// constant describes the rule rather than enforcing it. Read
/// `optimize_container` for what actually governs container selection.
pub let run_container_min_run_length : Int32 = 2
