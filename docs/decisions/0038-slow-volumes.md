# 0038. Slow volumes: dedicated threads, one blocking read per network volume, four on a local one

- **Date:** 2026-10-22
- **Status:** accepted

## Context

A directory read or a `statfs` on an SMB share that stopped answering blocks in the kernel for
tens of seconds, sometimes minutes. [0018](0018-listing-service.md) ran loads on a global GCD
queue with four slots: a load blocked on a hung share held its slot and its worker thread until
the call returned, so four hung loads stopped every pane, local ones too. The pane's folder
monitor read its volume with `statfs` on the same kind of queue. A `Task` is no better: the
cooperative pool has one thread per core, and a handful of blocked calls would stop every task in
the app. M2 adds the NAS (W4, W6), where this happens when the share is slowed or pulled.

## Decision

- **Dedicated threads.** Every directory read and `statfs` runs on a `BlockingCallThread`, a
  `Thread` started for that one call, at the QoS the caller asks for. `run` suspends the calling
  task on a continuation; `start` returns at once. `requireCurrent` traps unless it runs on such a
  thread, with a `dispatchPrecondition` against the main queue, and `VolumeIdentity(path:)` and
  `ListingService`'s read call it first. Moved off GCD: the load itself (was
  `ListingService.workers`), the root volume name read with it, and `PaneViewController`'s
  monitor start, which opens the folder and reads its volume.
- **Volume per load.** Each load first reads its folder's `VolumeIdentity` (`f_mntfromname`,
  `f_mntonname`, local or network) on a thread of its own, then waits in the queue. Loads stay in
  the order asked; the focused pane's still go first. A volume that can't be read fails the load
  with that error, as the read would.
- **Reads per volume.** A network volume has at most one read in flight; a local volume has up to
  `mostRunningLoads`, four. A second load on a share waits behind the first, even when the first
  is slow.
- **Slow gives up the slot.** A load that reads no batch for `LoadTimeouts.slow` (3 s) gets a
  `slow` update, once, and gives up its slot: a slow load must not block other loads on the same
  service. Its read stays in flight and still counts against its volume, and `full` or `failed`
  follows if the read returns. The timer restarts at each batch, so a share that stalls part way
  through a folder is slow too. Time comes from an injected `Clock`, so tests move it by hand.
- **Unreachable.** `ENOTCONN`, `ETIMEDOUT`, `EIO` and `EHOSTDOWN` have their own reason,
  `unreachable`.
- **One copy of the numbers.** `LoadTimeouts` holds the spinner delay (150 ms), the slow note
  (3 s) and the give-up time (30 s). No other copy existed; the panes read the first and last in
  M2.2 and M2.3.

## Alternatives considered

- **Keep the GCD queue and add more slots** — rejected: each hung call still holds a worker, and
  GCD stops adding threads at its own limit, which then stalls unrelated work on global queues.
- **Run loads as `Task`s** — rejected: see Context; 64 blocked calls on the pool would leave no
  thread for any task.
- **One read at a time per volume, local ones too** — rejected: a local volume keeps the four
  loads at once of [0006](0006-concurrency-shape.md), which ten large folders opening together
  need.
- **Cancel a slow read** — not possible: nothing interrupts a `getattrlistbulk` blocked in the
  kernel. The thread waits for it; only the slot is freed.
- **Slow only if nothing at all arrived** — rejected: a share pulled mid-listing would keep its
  slot for as long as the call blocks.
- **Read the volume in the load's slot** — rejected: `statfs` on a hung share blocks as long as a
  read, and would hold the slot before the per-volume limit could apply.

## Consequences

A hung share holds one thread blocked in a read, plus one blocked in `statfs` for each load that
asks for a path there while it hangs. Nothing bounds the second until a mount table can place a
path without a file-system call; the follow-up to consider is `getmntinfo(MNT_NOWAIT)`, which
reads the kernel's mount table without asking any volume, with a longest-prefix match of the
path against the mount points. Loads wait in the order asked, but a load can't start until its
volume read returns, so two requests made close together can start in the order their volume
reads finish rather than the order asked. Each load costs two
thread starts, tens of microseconds. A slow read that resumes keeps reading without a slot, so
five or more loads can briefly run at once. `ListingService(lister:)` without `volumeOf` puts
every path on one local volume, `listerVolume`, since a stub lister's paths aren't on disk.
`FolderMonitor`'s per-change `lstat` still runs on the FSEvents queue; FSEvents watches only local
volumes.

Amendment (M4.17): the last of the `mostRunningLoads` slots goes to a focused load only
([0048](0048-pane-load-priority.md)), so three hung loads, each holding a slot until the slow timer
fires, stop every non-focused pane from starting; a focused load still gets the last slot, and
a local volume's reads are likewise capped at three for background loads.
