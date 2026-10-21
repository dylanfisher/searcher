# 0004. Plain NSTableView, precomputed name sort keys, type icons in lists

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Key presses must move the selection within one frame (B6, 16 ms) and a sort change must redraw
within 150 ms (B8) at 100k rows. Finder feels slow on Dylan's SMB share even though listing it
takes under 6 ms. Spike S2 measured both (spike S2).

## Decision

List view is a view-based `NSTableView` with a plain data source. Each entry gets a name sort key
(case, accent and width folded; digit runs zero-padded) built off the main thread when the
listing arrives. List and column views show per-type icons; thumbnails are loaded only for Quick
Look and the gallery, off the main thread and cancelable.

## Alternatives considered

- **Sort with `localizedStandardCompare`** — rejected: 370 ms at 100k rows, over B8.
- **Parallel sort with `localizedStandardCompare`** — rejected: slower (489 ms); the comparisons
  contend across threads.
- **Per-file icons or thumbnails in lists** — rejected: a Quick Look thumbnail costs 85 ms per
  audio file over SMB.
- **Custom cell-drawing view** — not needed: per-key work is 1.6 ms median.

## Consequences

The sort key is an approximation of Finder's order and needs a wide test corpus. Folders with
custom icons show the generic folder icon. Revisit if the gallery or a "show previews" setting
moves thumbnails into lists.
