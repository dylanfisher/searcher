# 0117. Leave out entries whose names aren't UTF-8, and fail a listing on a malformed record

- **Date:** 2026-10-27
- **Status:** accepted

## Context

A security review found two faults in `DirectoryLister`'s parsing of `getattrlistbulk` records.

It decoded each name with `String(decoding:as: UTF8.self)`, which replaces bytes that aren't
UTF-8 with U+FFFD. APFS and HFS+ only hold valid UTF-8 names, but NFS, SMB, FUSE and FSKit
volumes can return other bytes: a Latin-1 "café" from an NFS server is `63 61 66 E9`. The
decoded name is not the file's name. Every operation builds its path as `path + "/" + name`, so
trash, rename, copy and open of that row reach no file (`ENOENT`) or, when the folder also holds
a file whose name is the decoded one, that other file. Two names that differ only in bytes that
aren't UTF-8 decode to the same `String`, and `ListingService` keeps only the last of them
([0018](0018-listing-service.md)).

It also trusted the record's lengths. A name reference with `attr_length` 0 made
`UnsafeRawBufferPointer(start:count:)` trap on a count of -1, and an `attr_dataoffset` or record
length past the record read outside it.

What Finder shows for such a name is *(unverified)*: an APFS test folder can't hold one, and no
NFS or FUSE volume was at hand.

## Decision

- **Leave the entry out and count it.** `DirectoryLister` validates each name with
  `String(validatingCString:)`. A name that isn't UTF-8 gives no entry; the lister counts it,
  and `Lister.listCountingUnreadableNames` returns the count. A lister that doesn't read the
  file system has every name as a `String`, so the protocol's default returns 0.
- **Say so in the pane.** `ListingService` puts the count on the full listing
  (`Listing.unreadableNameCount`), and the pane's status note, where the slow and offline notes
  go, reads "2 items with unreadable names aren't shown." while the folder is loaded. A slow or
  offline note takes the line before it.
- **Fail the listing on a malformed record.** A record whose length runs past the buffer, whose
  fields run past the record, whose name reference has length 0, points outside the record, or
  whose name doesn't end in its one NUL, fails the listing with `ListingError` `EBADMSG`. The
  pane shows it as any listing failure.

The validation replaces the decode, and costs the same: one pass over the name's bytes with an
ASCII fast path. The bounds checks are a compare per field. B2 and B5 on W2 and W5 measure it:
`./scripts/bench`.

## Alternatives considered

- **Keep the entry, marked, and have every operation refuse it** — rejected: the name still has
  to be a unique `String` for `Listing` and the repeat check, so it would need an invented name,
  and every operation, drag, Quick Look and Get Info would need the check. One missed path acts
  on another file.
- **Keep the name's bytes and build paths from them** — rejected: every path in the app is a
  `String`. Carrying bytes through rows, selections, operations and undo is a rewrite.
- **Escape the bad bytes, such as "caf%E9"** — rejected: the escaped name can be a real file in
  the same folder, and every path builder would have to undo the escape.
- **Fail the whole listing** — rejected: one stray name on a share would make the folder
  unbrowsable.

## Consequences

The user can't see, open or act on an entry with such a name in Searcher; the note says how many
there are, and Terminal can rename them. A folder walked for its size
(`listWithoutMountPoints`) leaves them out of the total. Cached rows of a network folder, and a
pane's recent listings, don't keep the count, so the note waits for the read that follows. A
listing patched by change watching keeps the count of its last full listing.
