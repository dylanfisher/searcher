# 0015. Sort rows as (column value, name rank) pairs; kinds from UTType by extension

- **Date:** 2026-10-20
- **Status:** accepted

## Context

A sort column change on 100k entries must redraw within 150 ms (B8), and the table's redraw took
about 60 ms in spike S2, so the model has a fraction of that. Single entries change through
FSEvents patches ([0005](0005-change-watching.md)) and must not re-sort the folder. The Kind column
needs text for every entry without reading files, off the main thread.

## Decision

`Listing` keeps the entries in arrival order and moves only `Int32` indexes. It keeps the
entries' name order and each entry's rank in it. Sorting by name copies that order; sorting by
another column sorts pairs of (column value as a `UInt64`, name rank), with the value inverted
when descending. Ties in every column go by ascending name in both directions, as in Finder.
Name order is `NameSortKey`, then the names' UTF-8 bytes: the build sorts by key alone and
then sorts each run of equal keys by bytes. Entries without a size sort below a
zero-byte file. Patches find an entry by binary search on name order and its row by binary
search on row order, then shift the index arrays: O(n) integer work, no re-sort.

`EntryKind` takes the type from the extension with `UTType(filenameExtension:conformingTo:)`:
`.data` for files, `.directory` for folders, kept for a folder only if it is a package. A type
without a description falls back to `.data` or `.folder`; symlinks are `.symbolicLink`, devices and
sockets `.item`. The text is `localizedDescription` with its first letter capitalized. A
process-wide cache behind a lock keeps one kind per file type and extension and one per type, and
`Listing` keeps a local table so a 100k build takes the lock once per extension.

## Alternatives considered

- **Sort indexes with a comparator that reads each entry** — rejected: 80 ms for 100k entries in
  a release build, against 6 ms for the pairs.
- **One name comparator that compares bytes when keys are equal** — rejected: 65 ms for 100k
  shuffled names, against 34 ms for key-only then runs, because each comparison that isn't less
  also tests the keys for equality. Reading the keys through `self` in a mutating method took
  140 ms.
- **Reverse the whole order when descending** — rejected: ties would go by descending name,
  which Finder doesn't do.
- **Break ties with `String` comparison** — rejected: it treats canonically equivalent names as
  equal, and a case-sensitive or SMB volume can hold both, so the order wouldn't be total.
- **Kind from `URLResourceValues.localizedTypeDescription`** — rejected: it reads the file, and
  costs 0.53 ms at p95 per file over SMB (spike S2).
- **Store the kind text per entry** — rejected: an index into a per-listing kind table costs 4
  bytes and gives the kind sort one integer per entry.

## Consequences

Rough numbers from a release build, 100k synthetic entries in shuffled order, 8 extensions: 50–55
ms to build (keys 8 ms, kinds 11 ms, name order 34 ms), 4–5 ms per change to size, date or kind,
and a copy for name. Patches at 100k, median of 20: insert 0.016 ms (it appends to the entries array),
remove 0.11 ms, and update of an existing entry about 0.1 ms, since it is a remove plus an
insert. Each is O(n); remove is dominated by moving the entries array. The model adds 13 MB
on top of the entries (measured on presorted input).

Kind text differs from Finder's in places: Finder says "Document" for an unknown extension and
"Unix executable" for an extension-less executable, which needs the file's mode; here both are
"Data". A symlink's kind is `UTType.symbolicLink`'s description, not Finder's "Alias".
