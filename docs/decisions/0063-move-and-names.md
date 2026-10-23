# 0063. Move with renamex_np, name copies as Finder does, read no-trash from the Cocoa error

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M4.3 gives Base the calls the operation queue makes for move, trash, new folder, rename and
duplicate, and the names Finder picks for Duplicate, Keep Both and New Folder. Users compare our
names with Finder's, so they should match. [0059](0059-trash.md) settles which trash API to use
but not how a volume without a trash shows up, and the plan leaves open how a name splits into
base and extension, what happens to a name too long for its suffix, and how a case-only rename
works on a case-insensitive volume.

`NSWorkspace.duplicate` names copies as Finder does, by its documentation. On macOS 26.6.2
(Mac17,6) it duplicated 54 items made for the purpose, in temp folders with and without other
names present; `UniqueNameTests` lists what it returned. What it showed:

- The extension splits off only where a declared type has it. "archive.tar.gz" duplicates as
  "archive.tar copy.gz", "App.app" as "App copy.app", "x.TXT" as "x copy.TXT", and a folder named
  "Stuff.txt" as "Stuff copy.txt". "Photos.2024", "x.qqq", ".zshrc", ".a.b" and "a.b c" get
  " copy" at the end. That is `UTType(filenameExtension:conformingTo: .item)?.isDeclared`, which
  also covers packages: "rtfd" and "framework" are declared only as packages, so they don't show
  up with the default `.data`.
- A name ending in " copy" or " copy N" continues from N + 1, whatever N is: "x copy 07" gives
  "x copy 8", "x copy 0" gives "x copy 1". The first free name wins: with only "report copy 2.txt"
  present, "report.txt" duplicates as "report copy.txt".
- A name with no room for " copy" fails with "File name too long".

There is no API for Keep Both. Dylan checked it in Finder on macOS 26: copying "report 3.jpg"
onto a folder's "report 3.jpg" and choosing Keep Both gave "report 3 2.jpg". Unlike Duplicate,
Keep Both doesn't continue a number the name already ends in.

`renamex_np` with `RENAME_EXCL` renamed "a.txt" to "A.txt" on case-insensitive APFS and HFS+
images without an error, so a case-only rename needs nothing extra.

`FileManager.trashItem`'s errors carry an OSStatus, not an errno: a missing file is Cocoa code 4
over `fnfErr`, a folder without write access is code 513 over `afpAccessDenied`.

## Decision

- **Move** is one `renamex_np(RENAME_EXCL)` call. `EXDEV` is `crossVolume` and the caller copies;
  `EEXIST` is `exists`, reported on the destination; every other error is reported on the source.
  On exFAT (macOS 26.6, exFAT disk image) `RENAME_EXCL` gives `EEXIST` when another item is at
  the destination, as elsewhere, and `ENOTSUP` when the destination is free or names the source
  itself, as in a case-only rename ("c" to "C"). On `ENOTSUP` the move `lstat`s the destination:
  an item there other than the source, one created since the first call, is `exists`;
  otherwise it is a plain `rename(2)`. Something created at the destination between the check
  and the rename is replaced; on exFAT that window is the price of moving at all.
- **Names** follow the duplicate rules above. Keep Both adds " 2", " 3" and on, the first free,
  after the whole base, with the same extension rule. `UniqueName` splits extensions with `UTType`, so Base imports
  `UniformTypeIdentifiers`, a system framework with no UI that Browser already uses.
- **Long names** are shortened by whole characters before the suffix until the name fits 255
  UTF-8 bytes, so a copy or a Keep Both still happens where Finder would fail. A suffix that alone
  passes 255 bytes would need a declared extension of about 245 bytes; none exists, so that case
  traps rather than throws.
- **No trash** is `CocoaError.featureUnsupported` from `trashItem`. Other trash errors map by
  their Cocoa code, or by the POSIX error underneath when there is one.
- **Permanent delete** is `Trasher.deletePermanently`, `FileManager.removeItem` on the path. It
  is the only permanent delete in Base. The operation queue calls it for delete immediately
  ([0065](0065-operation-queue.md)).
- **`:` is refused** in new names, as Finder refuses it.

## Alternatives considered

- **Split extensions with `pathExtension` alone** — rejected: it would give "Photos copy.2024"
  and "x copy.qqq" where Finder gives "Photos.2024 copy" and "x.qqq copy".
- **Pass "is a package" from the caller** — rejected: Finder splits a plain folder's declared
  extension too ("Stuff copy.txt"), so the item's kind doesn't decide it.
- **Fail on a name too long for its suffix, as Finder does** — rejected: a Keep Both in a copy
  of many items would fail one item for its name alone.
- **Rename with `rename(2)` after an `lstat` check** — rejected where `RENAME_EXCL` works:
  something created between the check and the rename would be replaced. It is the exFAT path.

## Consequences

The duplicate table is checked against the system, and Keep Both against one Finder run; the
rest of the Keep Both table follows from that run. An app that declares an extension changes how names with it
split, as it does in Finder. Copy names are English only. Whether a share or an exFAT volume
without a trash gives `featureUnsupported` is still open; the M4.13 SMB check settles it, and a
different error there changes only `Trasher`'s mapping.
