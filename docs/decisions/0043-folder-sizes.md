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

## Amendment: walks left running, one walk per folder, narrower drops, a drop log (M4.21)

Dylan saw sizes walked again on every return to a folder. The service changes in four ways (the
pane's side is in [0051](0051-folder-sizes-in-list.md)'s M4.21 amendment):

- **Leaving keeps running local walks.** `cancelWaitingWalks(for:)` replaces `cancelWalks(for:)`
  when a pane leaves its folder: a waiting walk never starts, a walk running on a share is
  cancelled as before, and one running on a local volume finishes and keeps its size, delivering
  nothing. A share keeps cancelling because it has one walk slot, which a walk nobody waits for
  mustn't hold. Unmounts, hidden tabs, closing, the setting going off and Recalculate Sizes still
  cancel every walk.
- **One walk per folder.** A request for a folder that a running walk is walking, at the same
  date on the same volume, left or not, waits for that walk's result instead of walking again,
  so a quick back-and-forth costs one walk. If that walk is cancelled, the requests that joined
  it go back in the queue and walk. A walk that waited also checks the cache when it starts, for
  a left walk of its folder that finished meanwhile.
- **Left walks give way.** A left walk can run for minutes (`~/Library`), and four of them would
  hold every slot while the folder on screen waits. When every slot is taken and a walk is
  waiting that a slot would start, the oldest running walk nobody waits for is cancelled, one per
  such waiting walk. Left walks keep every slot nobody else wants.
- **Lost events mark instead of drop.** A must-rescan event names the folder to read again, and
  the other events of its batch still count. Only the watched parent's children that hold that
  folder or are under it are in doubt: a folder deeper down is watched through its own parent,
  whose stream reports what happens under it, and every kept size's parent is watched or the size
  is already marked. A root-changed event, or a path outside the watched folder, puts every child
  of the parent in doubt. A size in doubt isn't dropped but marked: `size(of:modified:on:)` no
  longer gives it, so the next request walks the folder, and `keptSizes(of:)` still does, so a
  pane shows it while that walk runs. The folder's own date still drops it outright when it
  differs. A walk that started before the mark isn't kept, as before.
- **Eviction marks only the evicted parent's children**, for the same reason: past
  `mostWatchedFolders` the oldest parent's stream stops, and only its children were watched
  through it.
- **Drop log.** `FolderSizeCache` takes a `debugLog`; the app sends it to category `folderSizes`
  at debug level. Each drop or mark logs a line with the count, up to 20 paths and the reason (a
  change at a path, lost events at a path, a parent no longer watched, a changed folder date, or
  Recalculate Sizes). Nothing is logged when nothing was dropped.

Rejected: **ignoring `.DS_Store` and other noise** — sizes count every file, so a change to any
file has to drop its folders. **Dropping on lost events, as before** — the drop is what made a
revisit show "…" and walk everything under the parent again; a mark costs the same walk but only
for folders that are shown, and shows the old size meanwhile. **Letting share walks finish
too** — see above. **Capping left walks at two slots** — it holds two slots from the folder on
screen even when only one walk waits, and it stops nothing when the cap isn't reached; giving
way when a walk waits costs a left walk only when its slot is wanted, and loses that walk's
progress, which a revisit then walks again.

Consequences: a folder whose size is in doubt shows its old size, not "…", until its walk lands.
A left walk is cancelled whenever a shown folder needs its slot, so a big folder left behind
keeps its size only if nothing else was waiting while it ran.

## Amendment: sizes off by default, Calculate Sizes, throttled walks (M4.22)

Dylan: "folder sizes should be an option to enable/disable. its important we don't thrash the
disk. we should have a keyboard shortcut to calculate size in current folder". Finder's lead:
Calculate All Sizes is a view option, off by default, and folders show "--".

- **Off by default.** `Settings.folderSizes` defaults to false. View ▸ Calculate All Sizes
  (`SizeCommands.calculateAllSizes`, Finder's name) toggles it with a checkmark and persists it,
  as Folders First does. On, every list pane walks as before; off, the panes cancel running and
  waiting walks and drop the sizes shown. Kept sizes stay in `FolderSizeCache`.
- **Calculate Sizes, ⌥⌘S** (`SizeCommands.calculateSizes`), replaces Recalculate Sizes. In a
  list pane it drops the kept sizes under the pane's folder with `recalculateSizes(under:)`, as
  Recalculate Sizes did, then walks the folder's subfolders. With the setting on that is all it
  does. With it off it walks them once, and the folder shows the sizes the cache keeps from then
  on; the pane side is in [0051](0051-folder-sizes-in-list.md)'s M4.22 amendment. It is off in
  column view, as before. One command because both cases mean "walk this folder now": with the
  setting off nothing is kept to recalculate, and two items for the same walk would differ only
  by whether the setting is on. No other command has ⌥⌘S; Finder gives sizes no key.
- **Throttled disk reads.** Each walk's `BlockingCallThread` calls
  `setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)` before it reads
  (`FolderSizeService.throttleDiskReads()`), so a walk's reads wait while other I/O on the disk
  runs. The thread is the walk's own and ends with it, so no other work inherits the policy;
  listings, volume reads and Calculate Sizes' drop run on threads without it. Utility QoS alone
  isn't the same: `getiopolicy_np` reads `IOPOL_DEFAULT` on a utility thread, and xnu's QoS table
  gives utility I/O tier 1, the tier `IOPOL_STANDARD` names, where `IOPOL_THROTTLE` is tier 3.
  Measured on macOS 26 (Darwin 25.6): setting the policy also takes away the thread's QoS, so
  `qos_class_self()` reads unspecified and the base priority goes from utility's 20 to the
  default 31; `pthread_set_qos_class_self_np` then fails with `EPERM`. The walk thread is put back
  at utility's priority, 20, with `pthread_setschedparam`, so walks keep utility's CPU priority;
  the amendment of 2026-10-27 below says why that number isn't read from the thread. A test reads
  both on the walk thread. The four-walk and one-per-share caps are unchanged.

Rejected: **walks at background QoS** — xnu gives it I/O tier 2, not 3, its CPU priority is 4,
it runs only on efficiency cores and Low Power Mode defers it further, so a walk on screen would
slow far more than the disk needs; and `getiopolicy_np` can't show its tier. **`IOPOL_UTILITY`**
— tier 2, which still competes with listings more than tier 3. **A process-wide policy** — it
throttles listings. **Leaving the priority at 31** — walks would outrank every utility thread on
the CPU, the opposite of the point. **Keeping Recalculate Sizes beside Calculate Sizes** — see
above.

Consequences: a walk reads slower while anything else reads the disk, including listings and
other apps, by design; on an idle disk the throttle has no cost. A walk thread no longer has a
QoS class, so the scheduler treats it as a legacy thread at priority 20 rather than a utility
one, which can change which cores it runs on. The throttle applies to local disks; a share's
reads go over the network and are paced by its one-walk cap as before.

## Amendment: Calculate Sizes moves to Option-Command-S (2026-10-24)

Calculate Sizes was on Control-Command-S. The sidebar takes that chord, as Finder's does
([0086](0086-workspace-sidebar.md)), so Calculate Sizes is on Option-Command-S. No other command
uses it and it is not a system-wide macOS shortcut.

## Amendment: a walk's priority comes from its QoS, not a live reading (2026-10-27)

`throttleDiskReads()` read the thread's priority with `thread_info(THREAD_EXTENDED_INFO)` before
setting the policy and put that number back. That number is the kernel's live one: while a thread
of higher QoS waits on a lock the walk thread holds, the kernel raises the holder to the waiter's
priority, and `pth_priority`, `pth_curpri` and `THREAD_SCHED_TIMESHARE_INFO`'s `base_priority` all
read the raised value. A read during a raise put the walk back at 31 for good, the outcome the
function exists to prevent. Two tests read the same number and failed under load when a lock they
held was contended.

Measured on macOS 26 (Darwin 25.6), a utility thread holding an `os_unfair_lock` that a
user-initiated thread waits on, in a C harness:

- `thread_info` live priority: 31 while held, 20 on a fresh utility thread.
- `qos_class_self()` and `pthread_get_qos_class_np`: utility, relative priority 0, raised or not.
- `pthread_getschedparam`: 31 on a fresh utility thread whatever its QoS, since it reports what
  was last set with `pthread_setschedparam`, or the default; it is not the QoS's priority.
- `thread_policy_get(THREAD_PRECEDENCE_POLICY)`: 0 on a QoS thread; it only shows a priority set
  with `pthread_setschedparam`, relative to the task's 31.
- Putting back the live reading taken while held: 200 of 200 runs left the thread at 31 after the
  lock was let go. Putting back 20: 0 of 200.

No API reports the priority a QoS class asks for apart from the live one, so
`throttleDiskReads()` checks that the thread's requested QoS is utility with relative priority 0
and sets `FolderSizeService.utilityPriority`, 20, xnu's `BASEPRI_UTILITY` from its
`thread_qos_policy_params` table. It traps on any other QoS rather than guess a number for it:
walks are its only caller. The tests read the priority the thread set, with
`pthread_getschedparam`, and one holds a lock a user-initiated thread waits on until the live
priority shows the raise, then throttles and checks the thread asked for 20.

Rejected: **a table of every QoS class's priority** — the relative priority is scaled into the gap
below each class, and the task's QoS ceiling changes the result: in the process the harness ran
in, user-initiated threads read 31, and setting 37 after the throttle raised one above what it
had. **`min(20, live)`** — it would follow a ceiling below utility, but a raise during that
ceiling defeats it, and no such ceiling was seen. **Allowing a
tolerance in the tests** (the earlier fix) — a raise spans the whole gap to 31.
