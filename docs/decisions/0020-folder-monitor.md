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
"not found", a dropped or coalesced batch (`MustScanSubDirs`, `UserDropped`, `KernelDropped`) and a
change to the watched folder itself (`RootChanged`) each emit `relist` instead. A vnode watch emits
`relist` for every event.

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
- **Emit one change per event** — rejected: a burst of 1,000 creates would make 1,000 main-thread
  hand-offs; a batch is one.
- **Close the vnode descriptor in `stop` without waiting for the source** — rejected: the source
  still has the descriptor registered, and a reused descriptor number would be watched instead.

## Consequences

A burst of 1,000 creates in a local folder leaves the patched listing equal to a fresh one within
a few hundred milliseconds. An event for a file inside a subfolder is ignored, so a subfolder's
modified date in the list doesn't change until the next re-list. Each patch costs one `lstat`.
