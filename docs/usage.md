# Using moonbit-roaring

Practical guide to the parts of the API that are easy to get wrong, plus the
command-line tool. The [README](../README.md) covers what the package is and
why it exists; this page covers how to drive it.

Everything here was run against the checked-in code on `moon 0.1.20260920`.

## Table of contents

- [Choosing an operation](#choosing-an-operation)
- [Counting without materializing](#counting-without-materializing)
- [Ranges: half-open versus closed](#ranges-half-open-versus-closed)
- [Interop with another Roaring implementation](#interop-with-another-roaring-implementation)
- [The `roaring` command-line tool](#the-roaring-command-line-tool)
- [Reading the container statistics](#reading-the-container-statistics)

## Choosing an operation

Most of the API splits into "give me the set" and "tell me about the set".
Reaching for the wrong one is the usual source of wasted work, because every
materializing operation decodes both operands, merges them, re-optimizes the
container representation and re-boxes the result.

| You want | Use | Not |
| --- | --- | --- |
| The elements | `to_array()`, `iter()` | — |
| How many elements | `size()` | `to_array().length()` |
| Is a value present | `contains(v)` | `iter().contains(v)` |
| How many are in both | `and_cardinality(other)` | `intersect(other).size()` |
| Is `self` a subset | `is_subset(other)` | `intersect(other).size() == self.size()` |
| Similarity | `jaccard_similarity(other)` | manual union/intersect division |

`iter()` is lazy per bucket: `bm.iter().take(3)` decodes one container, not
the whole bitmap. `to_array()` decodes everything.

## Counting without materializing

The four cardinality methods answer size questions while producing only a
count. Their names follow CRoaring so the API reads the same across
languages.

```moonbit
let term_a = @roaring.RoaringBitmap::from_array([1U, 2U, 3U, 4U])
let term_b = @roaring.RoaringBitmap::from_array([3U, 4U, 5U, 6U])

assert_eq(term_a.and_cardinality(term_b), 2L)    // |A ∩ B|
assert_eq(term_a.or_cardinality(term_b), 6L)     // |A ∪ B|
assert_eq(term_a.andnot_cardinality(term_b), 2L) // |A \ B|
assert_eq(term_a.xor_cardinality(term_b), 4L)    // |A ⊕ B|
```

Disjoint bitmaps are answered from the cached per-container cardinalities
alone, without decoding anything. When both sides hold a `Bitmap` container
in the same bucket, the count comes from 1024 word-level popcounts instead of
two 65536-element array decodes.

Note that `and_cardinality`, `or_cardinality` and `xor_cardinality` are
symmetric; `andnot_cardinality` is the one directional operation.

### Counting inside a window

`range_cardinality(start, end)` answers "how many are in this window" for a
half-open interval, walking only the buckets the range touches:

```moonbit
let matched = term_a.intersect(term_b)
assert_eq(matched.range_cardinality(1000U, 2000U), 512L)
```

Half-open to match `add_range`, `remove_range` and `contains_range`. The
reference implementations disagree with each other about the convention here,
so this follows the package's own rather than either of them. It is also
cheaper and less error-prone than `rank(end - 1) - rank(start - 1)`, which has
to special-case `start`.

### Asking whether they overlap at all

`intersects` is a short-circuiting boolean, and it stops at the first shared
bucket rather than counting the whole intersection to answer a yes/no
question:

```moonbit
if query_terms.exists(term => index.intersects(term)) {
  // this document matches at least one term
}
```

### Why the return type is `Int64`

A `RoaringBitmap` can hold up to 2^32 values, which does not fit in MoonBit's
32-bit signed `Int`. CRoaring's counterparts return `uint64_t` for the same
reason, so these four methods return `Int64` and stay exact across the whole
representable range:

```moonbit
let low = @roaring.RoaringBitmap::new().add_range(0U, 2147483648U)
let high = @roaring.RoaringBitmap::new()
  .add_range(2147483648U, 4294967295U)
  .add(4294967295U)
assert_eq(low.or_cardinality(high), 4294967296L)
assert_eq(low.jaccard_similarity(high), 0.0)   // disjoint, not "both empty"
```

`size` and `rank` return `Int64` for the same reason.

### Countable versus materializable

The distinction matters, because it is not the whole API that is exact at that
scale:

| Works on any bitmap | Capped at 2147483647 elements |
| --- | --- |
| `size`, `rank`, `and/or/andnot/xor_cardinality` | `to_array`, `from_array` |
| `contains`, `contains_range`, `min`, `max` | `iter`, `add_many` |
| `serialize`, `deserialize`, `get_stats` | |
| `flip`, `is_subset`, `jaccard_similarity` | |
| `add_range`, `remove_range`, `add`, `remove` | |
| all the materializing set operations (`union`, …) | |

The cap on the right-hand column is MoonBit's own `Array` length limit, not
something this library chooses: an `Array[UInt]` simply cannot hold 2^31
elements. Calling `to_array()` on a bitmap that large will fail to allocate.
The left-hand column never materializes the set, so it is bounded only by the
32-bit value space itself.

In practice this rarely bites, because building such a bitmap in the first
place usually goes through the right-hand column. The realistic way to arrive
at one is `deserialize` of bytes produced by another implementation — which is
the interoperability case this package exists for, and the reason `size` was
changed to `Int64` rather than left to wrap.

`is_subset` is implemented as a direct containment walk rather than through
`andnot_cardinality`, so it cannot be fooled by a wrapped count into
reporting a non-subset as a subset.

## Ranges: half-open versus closed

There are two range conventions in the API, and mixing them up is a real
bug source rather than a style issue.

**Half-open `[start, end)`** — `from_range`, `add_range`, `remove_range`,
`contains_range`. A bucket fully covered by the range collapses to a single
`Run` in O(1), which is what makes bulk-loading a consecutive ID range cheap:

```moonbit
// 60,000 consecutive IDs become one Run container, four bytes of payload.
let window = @roaring.RoaringBitmap::from_range(0U, 60000U)
assert_eq(window.get_stats().run_containers, 1)
```

Because `end` is exclusive, these cannot express a range running through
`UInt`'s maximum value — `end` would have to overflow. Use `add` for that one
boundary value.

**Closed `[start, end]`** — `flip`, and the compatibility helper `range`.
`flip` matches CRoaring's `roaring_bitmap_flip`, and being closed is what
lets it name a range that reaches the top of the 32-bit space:

```moonbit
let bm = @roaring.RoaringBitmap::from_array([10U, 11U, 12U, 20U])
// 10..12 drop out, 13..19 arrive, 20 is outside the interval and survives.
assert_eq(bm.flip(10U, 19U).to_array(), [13U, 14U, 15U, 16U, 17U, 18U, 19U, 20U])
```

`flip` is an involution, so `bm.flip(a, b).flip(a, b) == bm`.

An inverted interval (`start > end`) is a no-op: the receiver comes back
unchanged. That matches CRoaring and this package's own `add_range` /
`remove_range`, and it avoids the far worse outcome of silently returning an
empty bitmap when a pair of bounds gets swapped.

One subtlety worth knowing: complementing a bucket over its *full* range
yields "everything the bucket did not already hold", which is empty only when
the bucket held everything. There is no cheap shortcut for that case, unlike
the corresponding `add_range` one.

## Interop with another Roaring implementation

The point of the package is that `serialize()` produces bytes another
implementation can read, and `deserialize()` reads theirs. Round-tripping
through your own code proves nothing on its own, which is why the test suite
decodes files generated by the official Java implementation and by
CRoaring.

To check a byte sequence you received from elsewhere:

```bash
moon run cmd/main -- check <hex>
```

To produce one for somewhere else:

```bash
moon run cmd/main -- encode 1 100 1000
# 3a30000001000000000002001000000001006400e803
```

`deserialize` is strict on purpose. It rejects truncated input, invalid
container offsets, unordered keys or array values, overlapping runs,
cardinality mismatches and trailing bytes, rather than reading out of bounds
or silently accepting a malformed bitmap. If a producer you trust is being
rejected, that rejection is the finding.

## The `roaring` command-line tool

`cmd/main` drives the portable format from a shell. Bytes travel as hex, so
there is no file I/O to configure and it runs on every target.

```bash
moon run cmd/main -- <command> [args]
```

### `info <hex>`

Decode portable bytes and report what they hold.

```bash
$ moon run cmd/main -- info 3b3003000f0000ffff0100ffff0200ffff03003f0d250000002b000000310000003700000001000000ffff01000000ffff01000000ffff010000003f0d
values          200000
min / max       0 / 199999
containers      4 (array 0, bitmap 0, run 4)
container bytes 24
serialized      61
```

That is a 200,000-value consecutive range in 61 bytes, stored as four `Run`
containers. `container bytes` is the payload alone; the remaining 37 bytes
are the cookie, the descriptive header, the run-flag bitset and the offset
header.

### `encode [values...] [--start N --end N]`

Build a bitmap and print its portable bytes as hex. Either list values, or
give a half-open range with `--start`/`--end`:

```bash
$ moon run cmd/main -- encode 1 100 1000
3a30000001000000000002001000000001006400e803

$ moon run cmd/main -- encode --start 1000 --end 5000
3b3000000100009f0f0100e8039f0f
```

### `check <hex>`

Verify a byte sequence round-trips exactly, and cross-check the bitmap's own
query methods.

```bash
$ moon run cmd/main -- check 3a30000001000000000002001000000001006400e803
ok: 3 values in 22 bytes, byte-for-byte round trip
```

Beyond the byte comparison, `check` asserts `rank(max) == size` and
`select(0) == min`, so a bitmap that encodes correctly but queries
inconsistently is still reported.

### Error handling

Failures print `error: ...` and exit without a stack trace:

```bash
$ moon run cmd/main -- info 3a300000
error: DeserializationError: truncated: missing container count

$ moon run cmd/main -- encode 1 abc
error: not a decimal number: abc
```

Hex input accepts an optional `0x`/`0X` prefix and any embedded whitespace,
so output can be pasted straight from another tool.

## Sizing and re-encoding after an interop read

Two methods exist specifically for the read side of interoperability.

`portable_size_in_bytes()` reports what `serialize()` will produce without
building it, which is what you need to pre-size a send buffer or enforce a
per-record byte budget. `get_stats().total_bytes_used` is the container payload
alone and says nothing about the headers.

```bash
$ moon run cmd/main -- info $(moon run cmd/main -- encode --start 1000 --end 5000)
values          4000
min / max       1000 / 4999
containers      1 (array 0, bitmap 0, run 1)
container bytes 6
serialized      15
```

`deserialize` keeps whatever representation the producer used, so a bitmap
read from portable bytes its producer left as an Array stays an Array forever.
`run_optimize()` re-encodes every container in its cheapest form — the same
cost model the normal mutation path applies automatically, with an entry point
for after an interop read:

```moonbit
let foreign = match @roaring.RoaringBitmap::deserialize(bytes) {
  Ok(b) => b
  Err(error) => panic("invalid bitmap: \{error}")
}
let optimized = foreign.run_optimize()
// Same elements, and now the same encoding this library would have produced
// from scratch.
let canonical = @roaring.RoaringBitmap::from_array(foreign.to_array())
assert_eq(optimized.serialize(), canonical.serialize())
```

Mirrors CRoaring's `roaring_bitmap_run_optimize` and Java's `runOptimize`.
Cardinality is unchanged, so no bucket is ever dropped.

## Importing ordered data

`from_array` sorts its input, which is wasted work when the data is already
ordered — the normal case for a database cursor, a file, or another bitmap's
`iter()`. `from_sorted` skips the sort:

```moonbit
let from_cursor = @roaring.RoaringBitmap::from_sorted(rows.map(r => r.id))
```

Duplicates are collapsed, so the input need not be strictly increasing.
Unsorted input produces a wrong result rather than an error: detecting it would
cost more than the sort it avoids.

## Reading the container statistics

`get_stats()` reports which representation each bucket ended up in. It is the
way to confirm that run compression actually happened rather than assuming
it:

```moonbit
let bm = @roaring.RoaringBitmap::from_range(0U, 60000U)
let stats = bm.get_stats()
assert_eq(stats.total_containers, 1)
assert_eq(stats.run_containers, 1)
```

`optimize_container` picks the cheapest of Array, Bitmap and Run by encoded
byte cost on every mutation path, so the representation you observe is the
one the data actually earned. A consecutive range always collapses to a
single cheap `Run`; forcing a `Bitmap` needs strided data that defeats
run-length encoding.
