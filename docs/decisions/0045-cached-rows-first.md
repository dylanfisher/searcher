# 0045. Cached rows first: placed by the mount table, kept after a full listing, offline with the rows

- **Date:** 2026-10-22
- **Status:** accepted

## Context

[0039](0039-listing-cache.md) built `ListingCache` and left it unwired: nothing looked listings
up or kept them, nothing flushed it on quit, and memory per volume had no bound. M2.3 has to show
a network folder's cached rows at once, list it behind them, and go offline with the rows when
the share stops answering (`ENOTCONN`, `ETIMEDOUT`, `EIO`, 30 s with nothing returned) or is no
longer mounted. A cache lookup needs the folder's volume, and [0038](0038-slow-volumes.md) reads
it with `statfs`, which blocks for as long as a hung share does. 0038 also reports a load slow
only once its read has started, so a load stuck in `statfs`, or queued behind a hung read on its
share, never said so. A pane's states, 0019's refresh on focus, 0033's Go to folder and 0036's
link opens were written for loads that either answer or fail. Columns are panes
([0041](0041-column-model.md)), so whatever a pane does, a column does.

## Decision

- **Cached rows before any `statfs`.** On the load's thread, the service first places the path
  in the kernel's mount table (`getmntinfo_r_np` with `MNT_NOWAIT`, `VolumeIdentity.mounted()`),
  which asks no volume. The longest network mount point holding the path, by its text, names
  the volume to look up. The cached entries are sorted on a `BlockingCallThread` and handed over
  as `ListingUpdate.cached`, with the date they were listed, and only then does the load read
  its volume with `statfs`. If that volume differs from the mount table's, as for a path through
  a link, the service looks up again with the volume `statfs` read before the load may start. A
  path the mount table doesn't place on a network volume gets its lookup after `statfs`, as
  before.
- **Kept after a full listing.** After a full listing on a network volume, the service starts an
  insert of its entries, dated then (`ListingCache.startInsert`). A load that fails part way
  keeps nothing. Local volumes skip the lookup and the insert.
- **Slow and given up, counted from the request.** Each load has a stall timer pair on the
  service's injected clock, started when the load is asked for and restarted at every batch:
  `slow` at `LoadTimeouts.slow` and `gaveUp` at `LoadTimeouts.giveUp`, each sent at most once
  and never after the load's last update. A hung `statfs`, a queue wait behind a hung read on
  the same share, and a share that stops part way through a folder all count. A share that keeps
  sending batches never goes offline. Cancelling a load stops its timers. The timers run on the
  concurrency pool, so they don't read the root volume's name: a `BlockingCallThread` of the
  load's reads it, and a report due before then waits for it. 0038's slot rule is unchanged: a
  read that has read nothing for 3 s gives up its slot, on a timer of its own that starts with
  the read.
- **New pane states.** `ListingState` gains `cachedRefreshing(rows, listedAt)`, `slow(kept?)` and
  `offline(kept?)`. Kept rows are whatever the pane showed: its own complete listing (dated when
  it landed), cached rows, or a first batch (undated). They also say whether they are a complete
  listing of the pane's own. A cached update shows only when the pane has no rows, since rows
  already shown are the folder's own and at least as new; a pane already slow or offline stays
  so, keeping the cached rows. A first batch doesn't replace complete
  rows, cached or the pane's own, so a reload, refresh on focus included, keeps the whole list
  until the new one lands, and keeps it if the share dies part way. Cached rows are resolved
  against like a first batch: a selected name they lack stays selected until the full listing.
- **Offline.** An `unreachable` failure, `gaveUp`, or `volumeGone` puts the pane offline with
  its rows. Every update carries the root volume's name, so a pane that gives up before anything
  else arrives can still show its path bar. The load keeps going, and its full listing still
  replaces the offline state.
- **A volume that is gone.** The service remembers each network volume it has read, by mount
  point. When a read of a path finds nothing (`ENOENT`, from the read or from `statfs`) under a
  remembered network volume, the service reads the volume at that mount point again. If it
  can't, or it is another volume, the update is `volumeGone`, after the remembered volume's
  cached rows for the path, if none came yet; otherwise `failed` as before.
- **Local folders.** A revisited local folder shows the rows a pane last showed of it, from
  memory, before its load starts, in the `cachedRefreshing` state
  ([0109](0109-recent-local-listings.md)). (Amended 2026-10-26: a revisited share folder does
  too, so the cached update that follows is ignored, since the pane has rows.)
- **Columns.** A column keeps the columns to its right while the cursor's entry is missing from
  rows that aren't a complete listing: a first batch or cached rows, slow, offline or not.
- **Go to folder and link opens move on fresh rows only.** Cached rows don't say whether the
  folder is still there, so a pending go keeps them and stays, as it stays on `slow` and
  `gaveUp`. The first update that does say moves the pane, and the kept cached rows show first.
- **Memory bound: entries.** `ListingCache.defaultEntryCap` is 200,000 entries in memory, twice
  W2. Past it, least recently used volumes leave memory first (their files stay). When the
  volume in use alone is past it, its least recently listed folders go, down to one folder of
  any size. Memory is what is saved, so a dropped folder also leaves the volume's file at its
  next write.
- **Quit.** The app makes the cache over `StoreRoots.user()` and a `ListingCacheStore` logging
  to the `cache` category. `applicationShouldTerminate` answers `terminateLater` and replies
  when `ListingCache.flush(by:clock:)` returns: when the flush, which first waits for every
  insert `startInsert` began, has written, or after 2 s, which logs a fault. A bench launch and
  the bench runner pass no cache; the B4 pane case uses an in-memory cache with no store.
- **UI bench.** The "load after Cmd-A on the first batch" case opened W2 again with a reload,
  which now shows no first batch. It now goes to W2's parent, untimed, and opens W2 from there.

## Alternatives considered

- **Use only the volumes loads have already read to place a path** — rejected: after a relaunch
  none are known, so a share that hangs at launch would show no cached rows.
- **Drop `statfs` and trust the mount table** — rejected: the mount table places a path by its
  text, so a path through a link or a firmlink lands on the wrong volume.
- **Cached rows count as first rows for Go to folder** — rejected: a folder deleted since it was
  cached would move the pane, take a history step, then fail.
- **A give-up timer in the pane** — the first version. Rejected: the pane sees only the first
  batch, so a folder still streaming 30 s after its first batch showed offline, and the pane
  needed a clock of its own.
- **Offline for every `ENOENT` on a network volume** — rejected: a folder deleted on a working
  share must say not found.
- **Bound memory by bytes** — rejected: the size of a `DirectoryEntry` in memory depends on its
  name's storage, which the cache can't see cheaply; entries are what B9 and the workloads count.
- **Drop folders from memory but keep them in the file** — rejected: a save writes the whole
  volume, so the cache would need to read the file back before each save, and a lookup that
  missed in memory would need to read it too, both on the load's way to its read.
- **Wait for the flush on quit without a limit** — rejected: a write that hangs would keep the
  app from quitting.

## Consequences

Each load starts three threads: the volume read, the root volume's name, and the read. A
volume's file is read on its first lookup, before that load's `statfs`, so the first folder
opened on a volume with a large file waits for the decode. A `statfs` on a hung share still
blocks its thread (0038); the cached rows, `slow` and `gaveUp` no longer wait for it, but the
load can't start until it returns. A pane that gave up still counts its load as running, so
focus doesn't list it again until the read returns or fails. A local folder left at a remembered
mount point after an unmount makes a missing folder there read as offline. Two shares mounted
one after the other at the same point can show the first's cached rows until `statfs` returns.
A quit that times out loses up to two seconds of listings. Go to folder into a hung share shows
nothing until the read answers; Esc gives up, as before. The memory bound holds one folder of
any size. M2.5 shows the spinner and the note; until then the list shows the rows, and `slow`
with no rows shows the spinner. Moving the UI bench case from reload to open adds a table
reload for the new folder to what it times, so its numbers aren't comparable with earlier runs.
