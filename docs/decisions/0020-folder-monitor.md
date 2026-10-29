# 0020. Folder monitor: patches read from the file system, lost events re-list

- **Date:** 2026-10-21
- **Status:** accepted

## Context

[0005](0005-change-watching.md) picks FSEvents for local volumes and a vnode watch for network
volumes. Building the monitor raised questions it doesn't answer: what a patch carries, what an
FSEvents batch can't be trusted for, which path to match events against, and how the watch ends.

## Decision

`FolderMonitor` turns each FSEvents batch into at most one `FolderChange`. It keeps only events for
the folder's direct children (amended 2026-10-28: and for items one level inside them, which count
as their child's, whose date and icon they change; see [0129](0129-row-icons-as-finder.md)),
reads each named child once with `lstat`, and emits `update` with the entry as it is now, or
`remove` if it is gone. The event flags aren't used for this, since one path can report create, modify and delete in the same batch. A `lstat` that fails for any reason but
"not found", dropped events (`UserDropped`, `KernelDropped`) and a change on the path to the watched
folder (`RootChanged`) each emit `relist` instead, whatever path the event names: FSEvents says a
drop means rescanning every folder the stream watches, and a `RootChanged` event names the watched
path, not the folder that moved. A coalesced `MustScanSubDirs` event emits `relist` only when its
path is the folder, one of its ancestors, or one of its direct children, whose own entry may be
stale. The stream watches everything under the folder, so a deeper one (a build folder or
`node_modules` churning below a child) can't change what the folder lists and is ignored; the
other events of its batch still patch. A vnode watch emits `relist` for every event.

Events are matched against the folder's `realpath`, because FSEvents reports resolved paths
(`/private/var/...` for `/var/...`). The stream asks for 0.1 s of latency with `NoDefer`, so a
quiet folder reports its first change at once and a burst arrives in batches.

A batch that names more direct children than `FolderChange.patchLimit` (1,000) emits `relist`
before reading any of them, and the pane relists when the patches waiting behind a running patch
or sort pass the same limit, so a burst sent as many small batches counts as one. (Amended
2026-10-27: unzipping 20,000 files into W2 would read 20,000 entries, then patch each, est. 5–10 s
on one queue.) Each patch shifts the listing's index arrays, O(n), and a relist costs O(n) once,
so the break-even count of patches is about a relist's cost per entry over a patch's cost per
entry and barely depends on n. At 100k entries [0015](0015-listing-model.md) measured an update
of an existing entry at 0.1 ms and an insert at 0.016 ms, against about 90 ms for a W2 relist
(B5): 1,000 updates cost about one relist, and 1,000 inserts a fifth of one. A smaller folder
lists faster in step with its patches, and a relist skips each patch's `lstat`. A relist keeps the
rows on screen until its full listing lands, and the selection, cursor and scroll follow it as
after any reload of the folder shown ([0029](0029-row-movement.md)). The bench cases
`W2: folder change adding <count> entries`, for 500, 5,000, 20,000 and 50,000 new entries
through `Pane.apply`, time both sides.

Changes reach the callback on a background queue, so the pane can patch a copy of its listing there:
`Listing.update` traps on the main thread. The initializers trap on the main thread too, since the
open and `statfs` calls block on a share that stopped answering. `stop` waits for the vnode
descriptor to close, which takes one queue hop.

## Alternatives considered

- **Patch from the event flags** — rejected: a file created and deleted inside one latency window
  reports both, and applying the flags in order would show a file that isn't there.
- **Relist on any `MustScanSubDirs`, whatever its path** — rejected: a churning folder deep
  under the shown one reports it on every 0.1 s batch, and each relist of a 100k-entry folder
  costs an estimated 300 ms of reading, sorting and patching on W2 (read, not measured).
- **Patch a direct child named by `MustScanSubDirs` instead of relisting** — not taken: it would
  be enough, since coalescing only names a folder above every path it covers, but a relist is
  the safe answer and a direct child of the shown folder is a rarer churn point than a deeper one.
- **Emit one change per event** — rejected: a burst of 1,000 creates would make 1,000 main-thread
  hand-offs; a batch is one.
- **A patch limit that grows with the folder, `max(500, n/50)`** — rejected: both sides of the
  trade grow with n, so a limit of 2,000 at W2 would let a batch cost two relists. The limit
  lives on `FolderChange`, where the monitor, which has the batch but not n, also reads it.
- **Patch the listing in place instead of a copy per batch** — not taken: the shown state holds
  the same arrays, so the first patch copies them once per batch, O(n), far below the patches
  themselves; avoiding it would mean the main actor giving up its rows while a patch runs.
- **Close the vnode descriptor in `stop` without waiting for the source** — rejected: the source
  still has the descriptor registered, and a reused descriptor number would be watched instead.

## Consequences

A burst of 1,000 creates in a local folder leaves the patched listing equal to a fresh one within
a few hundred milliseconds. An event for a file inside a subfolder is ignored, so a subfolder's
modified date in the list doesn't change until the next re-list. Each patch costs one `lstat`.
