# 0017. List view columns: sort direction, cell formats and who owns the sort

- **Date:** 2026-10-20
- **Status:** accepted

## Context

`0004-listing-view.md` makes the list a view-based `NSTableView` over a `Listing`
(`0015-listing-model.md`). The plan says header clicks sort and a second click reverses, and that
the list looks like Finder's, but not which way the first click sorts, how sizes and dates read,
or whether the table or the listing decides the sort when a new listing arrives.

## Decision

- **First click.** Name and Kind sort ascending on the first click; Size and Date Modified sort
  descending, largest and newest first, as in Finder. Each column's `sortDescriptorPrototype`
  holds that direction, and AppKit reverses the first descriptor on a second click.
- **The table owns the sort.** `ListingViewController.show(_:)` re-sorts a listing that arrives
  in another order to the header's column and direction, then reloads once and reselects the
  previously selected entries by name. A header click sorts the shown listing on the main
  thread: 4–5 ms at 100k entries (0015), well inside B8.
- **Sizes** use `ByteCountFormatter` with the file count style and every unit allowed, which reads
  "Zero bytes", "500 bytes" and "4.2 MB" with "KB" as Finder writes it. Anything without a size
  reads "--".
- **Dates** use `DateFormatter` with medium date, short time and relative formatting: "Today at
  9:41 AM", "Sep 13, 2020 at 12:26 PM".
- **Cells** are laid out with frames and autoresizing, not constraints, since B6 counts the cost
  of every row that scrolls in.
- **Tests set the sort descriptors** as a header click does instead of sending the click. A real
  click tracks the press in a nested run loop that stops the main run loop, and the test runner's
  async main exits the process when that run loop returns. Sent by hand to a window that is never
  shown, a real click did sort as the tests expect.

## Alternatives considered

- **Every column ascending first** — rejected: Finder puts the largest or newest first, and a
  user sorting by size or date is usually looking for those.
- **`ByteCountFormatStyle` (`Int64.formatted(.byteCount(style: .file))`)** — rejected: it writes
  "kB" and "Zero kB" where Finder writes "KB" and "Zero bytes". It takes a locale, which
  `ByteCountFormatter` doesn't, so size text follows the system locale.
- **Adopt each listing's own sort** — rejected: a reload built in name order would undo the
  user's header click.

## Consequences

When the pane model (M0.12) holds the sort column, the controller should take the sort from it
and report header clicks to it rather than keeping its own. Size text follows the system locale:
the region sets the decimal separator ("4,2 MB" in de_DE and fr_FR) and the language sets the
unit words. The tests use sizes without a decimal part, so the region doesn't change them, but
"Zero bytes" and "500 bytes" fail on a machine whose language isn't English.
