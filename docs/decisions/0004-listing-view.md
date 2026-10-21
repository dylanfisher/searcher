# 0004. Plain NSTableView, precomputed name sort keys, type icons in lists

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Key presses must move the selection within one frame (B6, 16 ms) and a sort change must redraw
within 150 ms (B8) at 100k rows. Finder feels slow on Dylan's SMB share even though listing it
takes under 6 ms. Spike S2 measured both (spike S2).

## Decision

List view is a view-based `NSTableView` with a plain data source. Each entry gets a name sort key
(case, accent and width folded; digit runs length-prefixed, so they compare by value at any
length; see [0013](0013-name-sort-key.md)) built off the main thread when the listing arrives.
List and column views show per-type icons, one `NSWorkspace.icon(for: UTType)` per type shared by
every row of that type (`TypeIconCache`); thumbnails are loaded only for Quick Look and the
gallery, off the main thread and cancelable.

## Alternatives considered

- **Sort with `localizedStandardCompare`** — rejected: 370 ms at 100k rows, over B8.
- **Parallel sort with `localizedStandardCompare`** — rejected: slower (489 ms); the comparisons
  contend across threads.
- **Per-file icons or thumbnails in lists** — rejected: a Quick Look thumbnail costs 85 ms per
  audio file over SMB.
- **Custom cell-drawing view** — not needed: per-key work is 1.6 ms median.

## Consequences

The sort key is an approximation of Finder's order and needs a wide test corpus. The corpus test
(`Tests/BaseTests/NameSortKeyTests.swift`) keeps four mismatches with `localizedStandardCompare`
on purpose:

- **Digit runs past `UInt64.max`.** `localizedStandardCompare` stops ordering them by value and
  puts x99999999999999999999 before x12345678901234567890. The key orders runs of any length by
  value.
- **Han by code point.** `localizedStandardCompare` orders Han by radical and stroke count, which
  files characters outside the main CJK block, such as 𠀀 (U+20000), among the main block. The key
  orders them by code point; matching would need the Unihan radical-stroke table.
- **Full-width zero runs.** ０, 00 and 000 share a key, since width and leading zeros are both
  folded, but Foundation's numeric compare doesn't call a full-width run equal to an ASCII one.
- **Bare Arabic hamza letters.** `localizedStandardCompare` puts a name first when it is a prefix
  of the other after canonical decomposition, so ا sorts before آ and مو before مؤمن, and the order
  isn't transitive (ؤ < ا < و < ؤ). The key follows the root order, which puts آ, أ, إ, ؤ and ئ
  before ا, و and ي.

Folders with custom icons show the generic folder icon. Revisit if the gallery or a "show
previews" setting moves thumbnails into lists.
