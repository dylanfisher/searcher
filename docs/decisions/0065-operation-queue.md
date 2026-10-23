# 0065. Operation queue: a lane per destination volume, refusals by path, snapshots every 100 ms

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
- **Lane order.** A lane starts its waiting operations in the order queued. An operation joins
  the lane only once its plan is done, so one still planning, such as a slow pre-scan or a read
  stuck on a share, can be overtaken by one queued after it.
- **Beside the lanes.** Rename, new folder, trash, delete immediately, and a move within one
  volume run as soon as they are planned, since each is one quick call per item.
- **Refusal by path.** An operation is refused at once, with the path, if it would change a path
  that an unfinished operation reads or changes, or read one an unfinished operation changes.
  Paths clash when one is at or under the other, compared without case, with Unicode
  normalized and without trailing slashes (`FileOperation.comparable`), as APFS compares names
  by default. The into-itself check compares the same way. On a case-sensitive volume this can
  refuse two different items, which is the safe side. Copies read their sources and change their
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
- **Cancel while planning.** A cancel finishes an operation still being planned at once: it
  never takes a lane, and whatever its plan thread returns later, perhaps minutes later from a
  `statfs` on a share that stopped answering, is dropped.
- **File totals.** `TreeSizeWalker.Total.files` counts every entry that isn't a folder:
  files, symlinks and the rest. That is what `FileCopier` counts, so "N of M files" ends at M.
  `OperationPlan.measure` counts a single file or symlink as one.
- **Snapshots.** The observer gets every operation's state at most once per 100 ms
  (`snapshotInterval`): the first change at once, later ones when the interval is up, so the last
  state always arrives. A finished operation is in one snapshot and then leaves the list, and
  nothing is sent once nothing is left. The copied bytes include the item being copied: the copy
  thread only stores its latest progress, and while anything runs the queue checks it once per
  interval, so `copyfile`'s report every 0.5 ms never calls into the actor. Each operation's
  `onFinish` gets its final state at once, outside the limit. Time comes from an injected
  `Clock`.
- **Pause.** A paused copy holds in `FileCopier`'s callback; other work holds before its next
  item. A paused operation keeps its lane.
- **Questions are awaited, not blocking.** The queue asks through `Prompts`, two async calls
  Interface answers: `resolve` for a `ConflictRequest`, `confirm` for a `ConfirmRequest`. The
  operation shows `waitingForAnswer` and every other operation keeps running, its own lane's
  included: conflicts are asked after the plan and before the operation joins its lane. A cancel
  or an unmount finishes a waiting operation at once, and the late answer is dropped. A question
  asked while an item runs (no Trash, below) is answered nil by a cancel or an unmount, so the
  operation cleans up what it staged before it finishes.
- **Conflicts per top-level item.** The plan `lstat`s each item's name in the destination folder
  and, when it is taken, the source, so the question shows both items' kind, size and date
  without Interface reading the disk. Nothing inside two folders of one name is compared;
  replace puts the whole folder in place, there is no merge. Answers are replace, skip or keep both,
  one question per conflict until an answer applies to all. Keep both takes
  `UniqueName.keepingBoth` when the item runs ("report 3.jpg" → "report 3 2.jpg"). An item
  onto itself, as a paste into the folder it came from, asks nothing: a copy takes Finder's
  Duplicate name (`UniqueName.duplicate`, "report copy.txt", then "report copy 2.txt"), as
  Finder names a paste there; a move does nothing.
- **Replace, trash first.** In this order, for each item answered replace:
  1. The item is staged in a new `.searcher-replace-<UUID>` folder beside the destination,
     under its own name: copied there, or moved there within one volume. A cancel up to the end
     of this step, including one that arrives as the copy returns, removes the staged item (or
     moves it back) and the folder, and leaves the original.
  2. The original goes to the Trash with `trashItem` from its own path, so Finder's Put Back
     works, and its URL goes into the record as `.replaced(path, originalTrashedTo:)`, listed
     before the change that put the new item there.
  3. The staged item moves to the original's path with `FileMover.move`, which refuses to
     replace anything, and the staging folder is removed.

  Between steps 2 and 3 the path is empty for the length of one rename, microseconds on a local
  disk. A crash there leaves the original in the Trash, where Put Back restores it, and the new
  item in the staging folder; nothing is deleted on its own. If step 3 fails, the original
  moves back from its Trash URL to its path, the staged item is removed, and the item fails
  with the move's error; if the move back fails too, that error is reported and the record
  keeps the Trash URL.
- **No Trash.** `noTrash` from a trash is how the queue learns a volume has no Trash; the failed
  call moved nothing. It then asks one `ConfirmRequest.deleteImmediately` for the operation and
  waits, the item where it was. For a trash it names this item and the ones after it; for a
  replace, this original and those of the later replaces, with the new item staged. Yes deletes
  the item, or the original with the record saying `.deleted(path)`, and every later one that
  has no Trash, without asking again. No ends the operation cancelled: a replace removes its
  staged item and leaves the original; earlier items, if any, stay as they went.
- **Unmount.** Queues add themselves to `VolumeEvents`, weakly, as panes do. Will-unmount fails
  every unfinished operation with a path at or under the mount point (comparable forms), source
  or destination, with `unreachable` on the mount point: one planning, asking or waiting in its
  lane at once, a running one as a cancel stops it, so `FileCopier` and the replace staging
  remove what was being written. What the cancel couldn't remove is a second error.
  Operations on other volumes go on.

## Alternatives considered

- **Count only regular files in the copier** — rejected: a symlink is an item the copy makes and
  Finder counts it, and the copier's count already included it; the walker counted no files,
  so it changed either way.
- **Strict queue order, plans included** — rejected: an operation's lane is known only once its
  volume is read, so waiting for every earlier plan means a plan stuck on a hung share holds back
  copies to every other volume.
- **Lanes in the order plans finish** — rejected: two copies queued one after the other to one
  disk would start in either order.
- **Case-sensitive path checks** — rejected: on APFS `/A/Album` and `/a/album` are one folder,
  so a rename or a copy into itself spelled with other case would slip through.
- **Every operation in a lane** — rejected: a rename would wait behind a 20-minute copy to the
  same disk, and it takes one call.
- **Refuse by lane, not by path** — rejected: it refuses a rename anywhere on a busy disk and
  doesn't stop a trash on another volume of a folder a copy reads.
- **Snapshots per operation, each limited on its own** — rejected: ten copies would send ten
  times the updates, and the panel draws all of them anyway.
- **Trash the source of a cross-volume move** — rejected: Finder deletes it, and the trash would
  fill with every item moved to another disk.
- **Swap the staged item into place (`renamex_np` with `RENAME_SWAP`), then trash the original
  from the staging folder** — the first version, rejected: the trashed original's Put Back
  pointed at the staging folder, which was gone; knowing before the swap whether the volume has
  a Trash took a probe (trash an empty file made for the purpose, then delete it from the
  Trash), since `FileManager.url(for: .trashDirectory, appropriateFor:)` threw
  `featureUnsupported` on HFS+, APFS and exFAT images that have one; and HFS+ and exFAT refuse
  `RENAME_SWAP` with `ENOTSUP`, so there the swap was three renames and not atomic anyway.
- **Ask about no Trash before staging** — rejected: it needs the probe above; asking with the
  new item staged costs only the copy when the answer is no.
- **Ask conflicts when the operation reaches its lane** — rejected: a copy queued behind a long
  one would ask only when that one ends, perhaps after the user has left; asking first also
  keeps a question from holding the lane.
- **Merge folders, as Finder's "Merge" does** — not now: the plan has conflicts per top-level
  item only; a merge would be a recursive conflict walk of its own.

## Consequences

Each operation's planning has its own thread, so a hundred queued copies plan at once with a
hundred threads, and a cancelled plan stuck on a dead share keeps its thread until the call
returns; nothing bounds either yet, which M4.4b (unmount) and M4.5 (commands that queue many
operations) should weigh. A queued copy whose pre-scan is slow can start after a later one to
the same disk. A refused operation names the path, and Interface words the message.
Each item runs on a thread of its own, about 50 ms of thread starts for a 1,000-item trash.
`Trasher.deletePermanently` now has a second caller, the cross-volume move, as its doc says.

Operations on paths reached through a link aren't matched by the refusal check, as 0049's panes
aren't, nor by will-unmount. Will-unmount fails an operation still planning, but its plan
thread stays stuck in a dead share's call as a cancel's does; no cap on plan threads was
added, since nothing here makes more of them. Each copy or move into a folder costs one
`lstat` per item, and one more per conflict, on the plan thread. A replace adds a folder, a
trash and a move per item. An item created at a name after the plan looked fails with
`exists`, as before; one created at the replaced path between steps 2 and 3 fails the move,
and the original comes back only if its path is free again. Whether an SMB share has a Trash,
and gives `noTrash` without one, is checked at M4.13. On exFAT, `FileMover.move` checks the
destination itself ([0063](0063-move-and-names.md)).
