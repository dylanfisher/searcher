# 00XX. Operation queue: a lane per destination volume, refusals by path, snapshots every 100 ms

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M4 adds copy, move, trash, rename, new folder, duplicate and delete. Base has the calls
([0062](0062-file-copier.md), [0063](0063-move-and-names.md)); something has to run them off the
main actor, keep two copies from fighting over one disk, keep a rename from pulling an item out
from under a copy, and tell the operations panel how far each one got without flooding the main
thread: `copyfile` reports every 0.5 ms at full speed ([0058](0058-copy-engine.md)). A copy or a
`statfs` on a share that stopped answering blocks its thread for minutes
([0038](0038-slow-volumes.md)).

The M4.2 review found that `FileCopier` counted symlinks as files while `TreeSizeWalker` counted
no files at all, and that a cancelled copy whose partial folder holds a locked file throws
`permissionDenied` and leaves the folder (0062), so "cancelled" alone would claim a clean cancel
that didn't happen.

## Decision

- **Plan first.** `OperationPlan` reads the volumes involved and pre-scans each item that will be
  copied, on a `BlockingCallThread`, before the operation waits for anything. A folder copied or
  moved into itself or a folder inside it is refused by the paths alone, before anything is read.
  An item that can't be read (gone, denied) fails alone; the rest run.
- **Lanes.** An operation that copies (copy, duplicate, a move to another volume) waits in the
  lane of the volume it copies to, keyed by `VolumeIdentity`, and a lane runs one operation at a
  time. Lanes run in parallel. A move is judged per item by the volume of the item's parent
  folder, read once per folder: one `statfs` per folder, not per item, on a share.
- **Beside the lanes.** Rename, new folder, trash, delete immediately, and a move within one
  volume run as soon as they are planned, since each is one quick call per item.
- **Refusal by path.** An operation is refused at once, with the path, if it would change a path
  that an unfinished operation reads or changes, or read one an unfinished operation changes.
  Paths clash when one is at or under the other. Copies read their sources and change their
  destinations; moves, renames, trashes and deletes change both ends. Two copies of one item to
  two places both only read it, so they run together. A duplicate's and a new folder's names
  are picked when they run, so those names are not checked.
- **Items, then errors.** An item's error is recorded with its path and the next item runs.
  `noSpace` and `unreachable` stop the operation, since every later item would fail the same
  way. The operation ends `done` with no errors, `failed` with any, `refused`, or `cancelled`.
- **Cross-volume move.** Each item is copied, then its source deleted with
  `Trasher.deletePermanently`; a failed copy leaves its source. A source that can't be deleted
  is that item's error, and the record names the copy as created, not moved.
- **Cancel says what it left.** `cancelled(leftBehind:)` carries the error `FileCopier` threw
  when it couldn't remove a cancelled partial item, with that item's path; nil means nothing of
  it is left. A cancel after an item's copy has finished lets that item's source delete finish.
- **File totals.** `TreeSizeWalker.Total.files` counts every entry that isn't a folder:
  files, symlinks and the rest. That is what `FileCopier` counts, so "N of M files" ends at M.
  `OperationPlan.measure` counts a single file or symlink as one.
- **Snapshots.** The observer gets every operation's state at most once per 100 ms
  (`snapshotInterval`): the first change at once, later ones when the interval is up, so the last
  state always arrives. A finished operation is in one snapshot and then leaves the list. The
  copied bytes include the item being copied. Each operation's `onFinish` gets its final state at
  once, outside the limit. Time comes from an injected `Clock`.
- **Pause.** A paused copy holds in `FileCopier`'s callback; other work holds before its next
  item. A paused operation keeps its lane.

## Alternatives considered

- **Count only regular files in the copier** — rejected: a symlink is an item the copy makes and
  Finder counts it, and the copier's count already included it; the walker counted no files,
  so it changed either way.
- **Lanes in the order queued** — rejected for now: an operation's lane is known only once its
  volume is read, so keeping queue order means a plan stuck on a hung share holds back copies to
  every other volume. Operations join their lane in the order their plans finish.
- **Every operation in a lane** — rejected: a rename would wait behind a 20-minute copy to the
  same disk, and it takes one call.
- **Refuse by lane, not by path** — rejected: it refuses a rename anywhere on a busy disk and
  doesn't stop a trash on another volume of a folder a copy reads.
- **Snapshots per operation, each limited on its own** — rejected: ten copies would send ten
  times the updates, and the panel draws all of them anyway.
- **Trash the source of a cross-volume move** — rejected: Finder deletes it, and the trash would
  fill with every item moved to another disk.

## Consequences

Each operation's planning has its own thread, so a hundred queued copies plan at once with a
hundred threads; nothing bounds that yet. A queued copy whose pre-scan is slow can start after a
later one to the same disk. A refused operation names the path, and Interface words the message.
Each item runs on a thread of its own, about 50 ms of thread starts for a 1,000-item trash.
`Trasher.deletePermanently` now has a second caller, the cross-volume move, as its doc says.
Operations on paths reached through a link aren't matched by the refusal check, as 0049's panes
aren't. Conflicts, replace, the no-trash question and unmount are M4.4b's.
