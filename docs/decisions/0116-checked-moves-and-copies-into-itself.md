# 0116. A move to another volume deletes only an unchanged source; into-itself is checked by identity

- **Date:** 2026-10-27
- **Status:** proposed
- **Amends:** [0065](0065-operation-queue.md): its "Cross-volume move" rule, which deletes each
  source once its copy returns, and its "Plan first" rule, which refuses a copy into itself "by
  the paths alone".

## Context

A security review found two ways a file operation could lose data or fill a disk.

0065 says: "Each item is copied, then its source deleted with `Trasher.deletePermanently`; a
failed copy leaves its source." Nothing looked at the source between the copy and the delete. If
a sync tool or an app wrote to it while it was copied, the delete removed the newer bytes and
only the older copy was left. A replace that moves to another volume deletes its source the
same way, and so does an undo that moves an item back across volumes.

0065 also says: "A folder copied or moved into itself or a folder inside it is refused by the
paths alone, before anything is read." `FileOperation.source(holding:among:)` compares the
folded path text. A destination reached through a symlink, such as `L` pointing at `A/sub`,
passed the check, and a copy of `A` into `L` copied into its own source until the disk filled.
0065's Consequences already noted that "operations on paths reached through a link aren't
matched by the refusal check".

The rules that bind the change: 0038 puts every blocking call on a `BlockingCallThread`, never
the main thread, since a call on a share that stopped answering blocks for minutes. 0072 records
a move to another volume "whose source couldn't be deleted" as a copy, `.created(path, from:
.copy(of: source))`, so its undo trashes the copy and leaves the source; Dylan's bar is that
undo has no edge cases.

## Decision

- **Stamp, copy, compare, delete.** Before a move to another volume copies an item, the item's
  thread reads its stamp (`OperationPlan.stamp`): the `lstat` of the item and, for a folder, of
  every item under it, read with `fts` without following symlinks, keyed by path. Each entry
  holds the device, inode, kind, logical size and modification time in nanoseconds, or the errno
  for an entry that couldn't be read. Once the copy returns, the source is deleted only when
  the copy is at the destination (the operation's identifier finds an item there) and a second
  stamp of the source equals the first: the same paths, each the same item, size and time.
- **A mismatch keeps both.** A source that changed fails its item with `changedDuringMove` on
  the source's path, and the copy stays, recorded as `.created(destination, from: .copy(of:
  source))`, the record 0072 already gives a source that couldn't be deleted. Undo trashes the
  copy and leaves the source as it is. A copy that is gone fails the item with `sourceGone` on
  the destination and records nothing. The copy isn't undone in either case. The operations
  panel says "“path” changed while it was copied, so it was kept, and the copy may be older."
  A source someone else deleted during the copy fails with `sourceGone` on the source's path
  instead, and its copy stays, recorded the same way.
- **Every copy-then-delete.** The plain move, the replace (stamp before staging, compare after
  the staged item is in place and the staging folder is gone), and an undo's move back across
  volumes all go through `deleteMovedSource`.
- **Cancel.** A cancel stops either stamp. During the first, the item ends cancelled with
  nothing written. During the second, the source and the copy both stay, and the operation ends
  cancelled with the copy recorded as made, so undo trashes it; a cancel after a large folder's
  copy then doesn't wait for a full walk and a delete. Once the second stamp matches, the delete
  runs to its end, as 0065 lets a finished copy's delete finish.
- **Into itself by identity.** After the path check, `OperationPlan.make` asks
  `OperationPlan.source(holding:among:)`: `realpath` resolves the destination folder, the folder
  and each folder above it up to `/` is `lstat`ed, and a source is refused with
  `.intoItself(source:)` when it is a folder (by `lstat`, so a symlink source, which a copy copies
  as a link, isn't) whose device and inode are among them. It runs on the plan's
  `BlockingCallThread`. A destination folder that can't be resolved fails the operation with
  that error, as a destination whose volume can't be read does. A source that can't be read is
  passed over here and fails alone in its pre-scan.

## Alternatives considered

- **Compare the stamp from the plan's pre-scan** — rejected: `TreeSizeWalker` lists with
  `getattrlistbulk` and reads no inodes, and an operation can wait in its lane long after its
  plan, so an edit made before the copy started would keep a source whose copy has it.
- **Compare only the top item's stamp** — rejected: writing a file inside a folder changes
  neither the folder's size nor its modification time.
- **Add the change time (`st_ctime`)** — rejected: it also changes when a dataless iCloud file
  is downloaded for the copy, or when an extended attribute such as a Finder tag is written, so
  every move from iCloud Drive would keep its source. Size and modification time are what the
  review asked for.
- **Trash the changed source instead of keeping it** — rejected: 0065 rejected trashing a moved
  source, and the user then has two versions with no way to tell which is newer.
- **Resolve symlinks only in the path check, still comparing text** — rejected: firmlinks, such
  as `/Users` and `/System/Volumes/Data/Users`, are one folder under two paths and aren't
  symlinks; device and inode match them.

## Consequences

A move to another volume walks each source twice more, before and after its copy, on the item's
thread: one `lstat` per item for a file, an `fts` walk for a folder, so a 100,000-item folder
costs two extra walks besides the copy. A stalled share blocks the walk as it blocks the copy.
A change that keeps an item's size and restores its modification time, made in place, isn't
seen. A write made between the second stamp and the end of `deletePermanently`'s walk is still
lost; closing that window would take a lock on the source, and macOS has none that every app
and every volume honors. On a slow share each stamp is a serial walk, one `lstat` per item, so moving a
100,000-item folder adds up to 200,000 round trips to the copy's own; how many the SMB client
answers from its cache is *(unverified)*. A folder's `.DS_Store` rewritten by Finder while the
folder is copied keeps the folder.
The copy-exists check finds an item at the destination, not a complete copy; `FileCopier`
returning without an error is what says the copy is complete. Whether Finder checks a source
before deleting it is *(unverified)*. That materializing a dataless iCloud file for a copy
leaves its size and modification time alone is *(unverified)*. A share that reports
the same inode for two folders would refuse a copy between them; none is known.

Each copy or move into a folder now costs a `realpath` of it and one `lstat` per folder above it
and per source on the plan thread, before its volume is read. The drop target's check on the main
thread (`DropOperation`) still compares paths only, since it can't read the disk; a drop through
a link into its source is refused when it is queued.
