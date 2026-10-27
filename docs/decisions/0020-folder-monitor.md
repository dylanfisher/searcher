# 0020. Folder monitor: patches read from the file system, lost events re-list

- **Date:** 2026-10-21
- **Status:** accepted

## Context

[0005](0005-change-watching.md) picks FSEvents for local volumes and a vnode watch for network
volumes. Building the monitor raised questions it doesn't answer: what a patch carries, what an
FSEvents batch can't be trusted for, which path to match events against, and how the watch ends.

## Decision

`FolderMonitor` turns each FSEvents batch into at most one `FolderChange`. It keeps only events for
the folder's direct children, reads each named child once with `lstat`, and emits `update` with the
entry as it is now, or `remove` if it is gone. The event flags aren't used for this, since one path
can report create, modify and delete in the same batch. A `lstat` that fails for any reason but
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
- **Close the vnode descriptor in `stop` without waiting for the source** — rejected: the source
  still has the descriptor registered, and a reused descriptor number would be watched instead.

## Consequences

A burst of 1,000 creates in a local folder leaves the patched listing equal to a fresh one within
a few hundred milliseconds. An event for a file inside a subfolder is ignored, so a subfolder's
modified date in the list doesn't change until the next re-list. Each patch costs one `lstat`.
