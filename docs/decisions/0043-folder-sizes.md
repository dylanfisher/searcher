# 0043. Folder sizes: a walk queue of its own, sizes dropped by change events or a new folder date

- **Date:** 2026-10-22
- **Status:** accepted

## Context

The list view shows each subfolder's size (M2.10), which takes a walk of everything under it:
B5 gives a W3 tree, ~60k files in ~8k folders, 2 s. Walks must not slow folder listings, so
[0006](0006-concurrency-shape.md) gives them a cancelable queue of their own at utility QoS, four
at once. On a share a walk is many blocking reads, and a share can stop answering
([0038](0038-slow-volumes.md)). A size goes stale when anything under the folder changes, which
the folder's own modification date doesn't show: it moves only when an entry directly in it is
added, removed or renamed. On a local volume FSEvents reports changes at any depth; on a share
it sees only this Mac's own changes, and a vnode watch sees only the one folder
([0005](0005-change-watching.md)).

## Decision

- **Walker.** `TreeSizeWalker` (Base) lists each folder with `DirectoryLister`, the same
  `getattrlistbulk` reader as listings, and adds up `ATTR_FILE_DATALENGTH`, the logical size, of
  regular files. Symlinks aren't followed. The walk lists with
  `DirectoryLister.listWithoutMountPoints(_:ifOnDevice:onBatch:)`, which asks for
  `ATTR_DIR_MOUNTSTATUS` and leaves out entries marked `DIR_MNTSTATUS_MNTPOINT`, so the walk
  never enters a folder another volume is mounted on; the root of the walk is still read. The
  device check alone isn't enough: `/`, `/System`, `/System/Volumes/Data`, `/Users` and
  `/Applications` share one device ID, so a walk of `/System` would walk the whole Data volume
  and a walk of `/` would count `/Users` and `/Applications` twice, once through the firmlink and
  once under `/System/Volumes/Data`. A test lists `/System/Volumes` read-only and finds `Data`
  left out, which is the step that stops a walk of `/System`. The device check, `fstat` of the
  open folder against the root's device, stays for a folder reached another way.
- **Errors.** A subfolder denied by permissions or privacy protection, or whose path is longer
  than a call takes (`ENAMETOOLONG`), is skipped and makes the total partial; one deleted or
  replaced mid-walk is skipped; any other error, such as a share that stopped answering, fails
  the walk. The root's errors always fail it. Cancellation is checked before each folder and
  each buffer.
- **iCloud.** A folder whose entry is dataless isn't entered and makes the total partial:
  listing it downloads its listing ([0030](0030-not-downloaded-badge.md)). A dataless file still
  counts its logical size, which comes with its parent's listing.
- **Hard links count once per link**, as `fts` with `FTS_PHYSICAL` counts them. Counting each
  file once needs the file ID and link count of every entry, which the listing doesn't read, and
  a set of IDs held for the whole walk.
- **Queue.** `FolderSizeService` runs at most `mostRunningWalks` (4) walks at once, each on a
  `BlockingCallThread` at utility QoS, and shares nothing with `ListingService`. Like a listing
  load, a walk first reads its folder's volume on a thread of its own, then waits in order. A
  share runs one walk at a time (`mostWalks(on:)`), for 0038's reason: its reads queue in the
  kernel anyway, and a hung share then holds one slot, not four. `cancelWalks(for:)` cancels a
  pane's walks; a running one stops before its next buffer, a waiting one never starts.
- **Kept sizes.** `FolderSizeCache` keeps each size with the folder's own modification date at
  the walk. A request names the date the pane's listing shows, and a size kept for another date
  is dropped and walked again. Nothing expires with time. Sizes on network volumes are also kept
  in the listing cache's volume file ([0039](0039-listing-cache.md)) as a `sizes` dictionary
  beside `folders`, with the same strict decoding: a file without it, as every file written
  before this change, fails to decode and is deleted.
- **Local changes.** Before a walk on a local volume reads anything, the service watches the
  folder's parent with a `FileEventStream`, one stream per parent shared by its subfolders. An
  event drops the size of the folder it names and of every kept folder above it; dropped or
  coalesced events drop every local size under the parent. A walk is registered with the cache
  before it reads, and an event under it during the walk keeps its result from being kept, so a
  result read before a change is never kept past the change's event. At most
  `mostWatchedFolders` (64) parents are watched; past that the least recently walked parent's
  stream stops and the local sizes under it are dropped. A parent that can't be watched gets its
  sizes delivered but not kept, and a log line.
- **Recalculate Sizes** is `recalculateSizes(under:)`: it drops the kept sizes of a folder and
  every folder under it, on disk too for a share, so the next request walks. The command and menu
  item land with the size column in M2.10.

## Alternatives considered

- **Feed size invalidation from the pane's `FolderMonitor`** — rejected: it reports only the
  folder's direct children, so passing deeper events means changing `FolderMonitor`, `Pane` and
  the pane controller, and a size kept for a folder no pane shows would never be dropped.
- **One FSEvents stream on each local volume's root** — rejected: every change on the disk would
  reach the app, and the boot volume's paths under firmlinks would need mapping.
- **A stream per walked folder** — rejected: a `node_modules` folder has hundreds of subfolders,
  each a stream; their parent is one.
- **Count each hard-linked file once** — rejected for now; see Decision.
- **Four walks on a share** — rejected: see Queue. Walks on different shares still run together.
- **A time limit on network sizes** — rejected by the plan: a library that rarely changes would
  be walked again for nothing, and the folder date plus Recalculate Sizes cover the rest.
- **A version field on the volume file** — rejected: stored data has one shape before release
  (AGENTS.md); old files are discarded.
- **A C walker** — not considered without a profile: 0003 found `getattrlistbulk` in Swift and C
  within noise.
- **Stay on the root's device only** — rejected: see Walker; the boot volume group shares one
  device ID.
- **Walk iCloud folders with a policy that keeps them from downloading** — rejected: the walk
  would depend on a per-thread I/O policy for correctness, and a skipped folder marked partial
  says the same thing honestly.

## Consequences

A share's sizes miss changes made below a subfolder by anyone, including this Mac, until that
folder's own date moves or the user runs Recalculate Sizes. Hard-linked trees, such as Time
Machine backups, read larger than the disk space they take. The service drops a local size on a
change but doesn't tell anyone; M2.10 decides whether a shown size is walked again. Two panes
asking for the same folder walk it twice. Kept sizes have no memory bound: every size is held
for the session, and a share's sizes for as long as the share is used. A walk on a share that
hangs holds one of the four slots until its read returns, since a blocked `getattrlistbulk`
can't be interrupted; the other three slots keep running. A folder in iCloud that isn't
downloaded reads as partial until it is. Saving a share's sizes when its listings aren't
pending re-reads the volume file to merge them in, a decode of up to the 50 MB cap per write;
saving listings uses the sizes the store already holds. Sizes count toward the cap with the
listings, so a volume that goes over it isn't written at all: neither its new listings nor its
new sizes reach the disk. Both accepted for now.
