# 0051. Folder sizes in the list: kept beside the listing, applied in batches through the patch path

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M2.10 shows each subfolder's size in the list view's Size column, from the walks
[0043](0043-folder-sizes.md) runs. A folder of a few thousand subfolders (`/Volumes/music/library`
has 3,177) gets a size every few milliseconds while the cache answers and one at a time while a
share walks, and each size can move a row when the list is sorted by size. B8 gives a re-sort
150 ms on W2, B10 and the rule against per-entry work on the main thread apply as they do to
sorts and patches ([0025](0025-sort-off-main.md), [0029](0029-row-movement.md)), and ↑↓ must stay
at B6 while sizes arrive. 0043 left open whether a shown size is walked again after a change.
`tmp/behavior.md` says nothing about folder sizes, so Recalculate Sizes has no chord and the
setting no menu item.

## Decision

- **Where a size lives.** `Listing` keeps a `FolderSizeValue?` per entry beside its other
  per-entry arrays: a size with its partial flag, or a failed walk; nil until the walk ends.
  The Size sort reads it for folders, so a folder not walked yet sorts as before, below a
  zero-byte file. A patch that replaces a folder keeps its size while the folder's own date is
  the same. A size names the date it was walked at and isn't applied to a folder showing
  another date. Sizes go in and are kept by `ExactName`, since `String` takes canonically equal
  names, which a folder can hold side by side, as one.
- **Batches.** The pane queues each size as it arrives and applies the queue at most once per
  250 ms (`Pane.sizeBatchInterval`): to a copy of the rows on the queue patches use, re-sorting
  when sorted by size and resolving the selection there with `.sameEntries`, so it follows its
  names. Batches and patches take turns through `patchIsRunning`, both wait for a running sort,
  and each landing starts the other. The first size after a quiet 250 ms goes out at once, and a
  batch that has waited out the interval goes before the next patch, so a folder that keeps
  changing can't hold sizes back. A batch that sorts by size sorts all the rows again instead of
  moving each folder's row: a sort of 100k entries is about 6 ms in a release build, where moving
  rows shifts the row array once per size.
- **Which folders are walked.** After each change of the rows a scan, on a utility queue, finds
  the folder rows not yet asked for at their current date and asks for them there, in one
  `FolderSizeService.requestSizes` call under a `PaneID` of its own. That call reads the volume
  once, at the pane's folder, with the mount table (`getmntinfo` with `MNT_NOWAIT`, which asks no
  volume), and starts one task for the lot; a scan that finds nothing to ask for reads nothing,
  since on a share that stopped answering each read holds its thread for good. 0043's limits of
  four walks, one on a share, still hold. A subfolder another volume is mounted on, as a share
  under `/Volumes` is, is found by its path in the mount table and walked as that volume's: one
  walk at a time on a share, its size kept with the share's and written to its volume file, and
  no FSEvents stream for it. Only rows shown are walked: hidden and filtered-out folders are
  asked for once they show. A pane asks only while it shows sizes (list view, a service, the setting
  on), is in the selected tab, and its volume is mounted.
- **When walks stop.** Leaving the folder, switching to columns, closing and turning the setting
  off cancel the walks and forget the folder's sizes. A pane whose tab is hidden, or whose volume
  is about to unmount or has unmounted, cancels its walks and keeps the sizes it has; the next
  scan, when the tab shows or the folder is listed again, asks for the rest. A running walk holds
  a folder open, which can keep a volume from unmounting, so a volume about to unmount also
  cancels every pane's walks at or under its mount point (`cancelWalks(under:)`), those of a
  pane above it included. Such a folder shows "…" until its parent is listed again. A hidden
  tab's pane mustn't hold a share's one walk while the focused pane waits for sizes.
- **Lists of the same folder.** The pane keeps the sizes walked for the folder it shows and
  applies them on the load's worker to each new listing of it, so a reload (each focus change
  reloads) shows them at once and doesn't walk again. The same scan queues any known size a new
  listing lacks, for a load that started before the size arrived. A load started before the
  setting was turned off drops its sizes in the next batch.
- **Failed walks** show "--" and aren't kept as known sizes. They are asked for again when the
  folder is fully listed again (a reload, focus, or a remount, which lists it again), not on the
  next scan: every batch is followed by a scan, so a folder whose walk keeps failing, such as one
  on a share that stopped answering, would walk again every 250 ms.
- **When a shown size is walked again.** When the listing shows another date for the folder
  (an entry added, removed or renamed directly in it), on a later visit to the parent, where the
  service's cache answers unless a change under the folder dropped it, and on Recalculate Sizes.
  A change deeper down doesn't re-walk a folder while the pane stays.
- **Text.** `EntryCellFormatter` holds every string: "…" until the walk ends, the size, "≥ "
  before a partial one, and "--" for a failed walk and for folders when sizes aren't shown.
- **Recalculate Sizes** (`SizeCommands`) drops the kept sizes under the pane's folder, then the
  pane forgets its own and walks its folders again, keeping the shown sizes until the new ones
  land. The pane forgets only after the drop, so a reload or batch meanwhile can't fill it back
  from the cache. A drop that can't read the volume is logged and changes nothing. It has no
  chord; the View menu runs it, and it is off where the pane shows no folder sizes, column view
  included.
- **Bench.** "W2: size updates re-sorted" times a batch with a size for each of W2's 1,000
  folders applied to the listing sorted by size, with the selection resolved: the work the pane
  does off the main actor per batch, the model part of B8.

## Alternatives considered

- **A size per entry in `DirectoryEntry`** — rejected: it is Base's file-system record, and a
  walk result with its partial flag and failure is Browser's.
- **Sizes keyed by `String` name** — rejected: two canonically equal names share one key, and
  the scan asks for one of them forever.
- **Apply each size as it arrives** — rejected by the plan: a sort per size on the main
  thread, or a landed state per size, every few milliseconds while the cache answers.
- **Send sizes through `FolderChange.Patch`** — rejected: patches on rows that aren't fully
  loaded relist the folder, and sizes arrive during first batches and offline states too.
- **Ask for each folder with `requestSize`** — rejected: a volume read on a thread of its own
  and a task per folder, 3,177 of each for the library, started from the main thread.
- **Walk again after every reload** — rejected: each focus change reloads; the cache would
  answer, but a request per folder per focus change for nothing.
- **Keep walking in hidden tabs** — rejected: on a share one walk runs at a time, and a hidden
  pane's walk would hold it while the focused pane shows "…".

## Consequences

Each change of the rows scans them once off the main actor, about one pass over the rows; a
folder that patches every 0.1 s scans as often. A volume mounted below the pane's folder is
found by its mount point's path, as `VolumeEvents` finds panes, so one reached through a link
isn't: it is walked as the parent's. A failed walk isn't
retried until the folder is listed again or Recalculate Sizes runs. Sizes cost 16 bytes per
entry in each listing, files included. A sort started while a batch runs is dropped when the
batch lands and started again, as with a patch. The setting has no menu item; `defaults write`
changes it until the config file (M5b.1) does.

## Amendment: sizes on a revisit's first rows (M4.21)

Going back to a folder showed "…" for every subfolder until the scan, the service's volume read,
its cache lookups and a batch refilled them, which reads as walking again.

- **Leaving lets local walks finish.** Leaving the folder calls
  `FolderSizeService.cancelWaitingWalks(for:)` ([0043](0043-folder-sizes.md), M4.21 amendment):
  walks running on a local volume finish and keep their sizes for the next visit. The pane still
  forgets its own sizes and drops any result that lands after it left. Switching to columns,
  closing, the setting going off, hidden tabs, unmounts and Recalculate Sizes still cancel every
  walk.
- **Kept sizes go on the first rows.** The load's worker applies, beside the pane's own sizes for
  a reload, the sizes `FolderSizeService.keptSizes(of:)` holds in memory for the listing's folder
  rows at the dates they show, so the first rows of a revisit, cached or listed, have them. It is
  one lock and a dictionary lookup per folder row, on the load's worker, with no file read. The
  scan after the rows land asks for each folder as before, and the service's checks decide: a
  size it still holds answers at once, and one dropped or marked since is walked again, the rows
  showing the old size meanwhile.

Rejected: **the pane keeping the last few folders' size maps by `Location`** — a second copy of
sizes the service already holds, one that `FolderSizeCache`'s drops wouldn't reach, so a size
dropped for a change would come back on the next visit until the scan replaced it. A read of the
cache's memory has one source and sees every drop. **Waiting for the actor in load prep** — the
load's worker would wait behind walks finishing and network volume file reads.

Consequences: a share's sizes not yet read from its volume file this session aren't on the first
rows; the scan's request reads them, as before. B4 now includes this lookup on the load's worker.

## Amendment: sizes on request (M4.22)

The setting is off by default and Calculate Sizes (⌥⌘S) walks one folder on request
([0043](0043-folder-sizes.md)'s M4.22 amendment). The pane's side:

- **Which folders show sizes.** `Pane.showsFolderSizes` is true in a list pane with a service
  when the setting is on, or when the pane's folder is one it ran Calculate Sizes in with the
  setting off (`calculatedFolders`, by path). Turning the setting off empties that set. A visit
  to such a folder applies the kept sizes to its first rows as before, and its scan reapplies
  known sizes but asks for no walk, so a revisit, a reload and a change event walk nothing.
- **Once.** With the setting off, Calculate Sizes sets `calculatesSizesOnce`; the next scan asks
  for every folder row the cache doesn't answer, notes the asked names in `calculatingSizes`, and
  clears the flag. Later scans in that folder ask for nothing, so a subfolder that changes shows
  "--" until Calculate Sizes runs again. Leaving the folder clears both, and walks behave as
  before: local ones finish and keep their sizes, share ones are cancelled.
- **Text.** `Pane.awaitsFolderSizes` says whether a folder row without a size waits for a walk:
  the setting is on, or the once scan's walks haven't all landed. `EntryCellFormatter` shows "…"
  for it then and "--" otherwise, as it already did for a failed walk and for panes without
  sizes.

Rejected: **sharing `calculatedFolders` across panes in the service** — the request is the
pane's, and the other pane can run the chord; a set in the pane needs no lock. **Walking new
subfolders after a change while the folder stays shown** — that is what the setting is for, and
"once" is what keeps the disk quiet with it off.

Consequences: a folder calculated in one pane shows "--" in another until that pane runs the
chord, which drops the kept sizes and walks them again. A size the cache marks as in doubt still shows
on a revisit with the setting off, since nothing walks it again; Calculate Sizes replaces it.
The calculated folders last for the pane's life.

Amendment (2026-10-24): Calculate Sizes is on Option-Command-S, not Control-Command-S
([0043](0043-folder-sizes.md)).
