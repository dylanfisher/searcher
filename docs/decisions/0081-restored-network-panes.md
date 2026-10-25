# 0081. Restored network panes: cache files read with the session, found by mount point

- **Date:** 2026-10-24
- **Status:** accepted

## Context

M5a.3 has to show a restored pane on a share with its cached rows at once (B4, 16 ms from the
window shown), and a pane on a share that isn't mounted with its cached rows and the offline
state, without launch waiting on any share. [0045](0045-cached-rows-first.md) places a folder on
a volume with the mount table, and reads the volume's file on the first lookup, inside the
pane's load. After a relaunch with the share unmounted, the mount table has no volume for the
path, the load's `statfs` finds nothing, no volume was remembered, and the pane showed the
missing state ([0080](0080-restore-at-launch.md)). A cache file is named by a hash of the
device and mount point ([0039](0039-listing-cache.md)), so without the device the file can't be
found. The entry cap and the store's 50 MB cap could drop the folders a saved workspace shows.

## Decision

- **Read with the session.** The launch's task that reads `WorkspaceStore` then calls
  `ListingCache.restore` with the folder of every pane of every stored workspace, before the
  windows are built. It reads the kernel's mount table (`getmntinfo` with `MNT_NOWAIT`, which
  asks no volume) on a `BlockingCallThread`, and the cache files, which are local. The windows
  wait for this read: they are built only once it ends, so B1 includes reading and decoding
  the restored panes' volume files. No share is read before the windows show.
- **Mounted shares.** A folder the mount table places on a network volume has that volume's file
  read into memory, so the pane's lookup finds it without a file read.
- **Rows in the first frame** (amended 2026-10-24). The lookup found the rows 0.4 ms into the
  restore, but handed them on the main queue, behind the restore, which made and showed the
  window in the same main-queue block. The window's first frame showed the pane loading, and
  the rows came in a second frame, 47 ms after the window was shown (p95, on `/Volumes/music`).
  `WorkspaceWindows.restore` now makes the panes, waits for each one in a selected tab to have
  its cached rows (`Pane.cachedRowsHanded()`), and only then makes and shows the windows. The
  wait ends on the main queue right behind the rows' hand-off, once the cache has been asked
  and before the volume read, so it never waits on a share; a folder the cache isn't asked for
  first, as a local one, ends it as soon as the load is placed, and a cancelled load ends it at
  once. The wait is capped at 300 ms (`WorkspaceWindows.cachedRowsLimit`): past it, the
  restore logs a fault naming the folders of the panes still waiting and shows the windows
  anyway, so a cache that stops answering can't stop the launch. Saves stay held during the
  wait. Local panes wait too, a few main-queue hops each, so B1's restored session should be
  timed again on an idle machine. The full listing still replaces the rows when it lands.
- **Shares that aren't mounted.** A cache file is now named
  `<sha256(mount point)>-<sha256(device, mount point)>.plist`. For a folder the mount table
  doesn't place past a shorter mount point, the store lists its folder once and reads the file
  of the longest mount point holding the folder; of several volumes mounted there one after the
  other, the file written last. The volume goes in memory and in `restoredVolume(holding:)`.
  `ListingService.place` uses it when the mount table has nothing longer: it hands the cached
  rows, remembers the volume as one loads were on, and the `statfs` that then finds nothing
  there ends the load `volumeGone`, which shows the pane offline with the rows (0045). The pane
  needs no change: its existing states do this.
- **Kept through the caps.** The restored folders stay in memory past the entry and volume
  caps, and so do their volumes; other folders and volumes go first. Their volumes' files stay
  past the store's byte cap. What is kept is set at launch from the stored workspaces, saved and
  open alike.
- **One shape.** A file in the listings folder not named as above, including every file named
  by 0039's hash, is deleted and logged at the next write. An undecodable file is deleted as
  before, whether read by volume or by mount point, and the pane loads as it would with no file.
- **UI bench.** `restored-network-pane --path <dir>` lists the folder once through a cache over
  a store in the temporary root, flushes it, then restores a one-window session on the folder
  through `WorkspaceStore`, `ListingCache.restore` and `WorkspaceWindows.restore`, as a launch
  does, and times the window shown to the frame with its cached rows (B4), 20 launches. A pane
  without rows as its window is shown fails the launch; rows of the folder's own listing that
  beat the first frame count, since the cache was checked to keep the folder first. That frame
  is the first of a fresh process, so it includes setting up the table, its cells and the
  window's backing store.

## Alternatives considered

- **Store each pane's volume in `TabState`** — rejected: the pane would need its volume from
  its loads, and a second copy of the volume would live beside the cache's.
- **Decode every cache file at launch to find the unmounted ones** — rejected: up to 50 MB of
  decoding inside B1 for files no restored pane needs.
- **Show the window before the cache read ends** — rejected: the pane on an unmounted share
  would load before its volume is known and show missing, and a mounted pane's rows would wait
  for the decode inside its load anyway.
- **Keep the folders of saved workspaces only as of the launch** — rejected: a workspace named,
  or a pane moved, during the session went unprotected until the next launch. Each save that
  writes or deletes a workspace now gives the cache the folders of every stored workspace
  (`ListingCache.keep(folders:)`), computed as the launch computes them.

## Consequences

The first launch after this change discards every cache file, so network folders list once
without cached rows. A folder on the startup disk at an unmounted share's path shows the
share's cached rows until its own listing lands. A pane on a
share that is mounted elsewhere, as `/Volumes/music-1`, shows offline with the old rows.
