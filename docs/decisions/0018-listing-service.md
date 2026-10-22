# 0018. Listing service: first batch on a second read, dispatch threads, fresh-process B9

- **Date:** 2026-10-20
- **Status:** accepted

## Context

[0006](0006-concurrency-shape.md) fixes the service's shape: at most four loads at once at
userInitiated QoS, the focused pane first, a sorted 200-entry first batch, then the full listing.
Building it raised questions 0006 doesn't answer. The service can't tell from one batch whether
more will follow. Loads block in `getattrlistbulk`, and on a share they can block for seconds.
`Listing` traps on two entries with the same bytes, and a lister can repeat a name, as SMB does
while a folder changes. The main actor has to get updates in order, and a pane that navigates away
must not get one after it cancels. B9 is the footprint a loaded W2 listing adds, measured in a
bench process that has already loaded W2 many times.

## Decision

The first batch goes out when the lister delivers its second batch and at least 200 entries have
arrived. It holds the first 200 read, sorted. A folder read in one batch (a W1 folder is about 300
entries, and one 256 KB buffer holds about 2,000) gets only the full listing.

Loads run on `DispatchQueue.global(qos: .userInitiated)`, never on the Swift concurrency pool
(superseded: they now run on `BlockingCallThread`s, see [0038](0038-slow-volumes.md)). One
serial queue owns the waiting loads and the running count, so `load` costs its caller one
`async`. A repeated name replaces the earlier entry in place: names are compared by their UTF-8
bytes, as `Listing` compares them, and the last entry read wins. Updates go out with
`DispatchQueue.main.async` and `MainActor.assumeIsolated`, and each checks the load's cancel flag
there, on the main actor, before it runs the pane's handler.

The B9 case runs `Bench --footprint-of-opening <folder>` in a new process for each sample. The
bench runner runs the main run loop instead of `dispatchMain`.

## Alternatives considered

- **First batch once 200 entries have arrived** — rejected: a W1 folder arrives in one batch of
  about 300, so it would get a first batch and a full listing a fraction of a millisecond apart, and
  rows would reorder for nothing.
- **Loads as `Task`s** — rejected: a blocked `getattrlistbulk` holds a pool thread, and four loads
  on a hung share would hold half the pool on an 8-core machine.
- **Fail a load whose lister repeats a name** — rejected: a folder that changes while it's listed
  would fail to open on a share, where it is common. The next re-list corrects the entry.
- **`String` hashing to find repeats** — rejected: it treats canonically equivalent names as equal,
  and a case-sensitive or SMB volume can hold both as separate files.
- **`Task { @MainActor in }` for the hand-off** — rejected: the order two tasks run in isn't
  promised, and a first batch must not arrive after the full listing.
- **B9 in the runner's own process** — rejected: only the first W2 load showed its footprint
  (41–42 MB). Later loads reuse pages that earlier loads freed and that stay in the footprint, so
  they read 0–4 MB. `malloc_zone_pressure_relief` didn't return them.
- **`dispatchMain` in the runner** — rejected: it parks the main thread and runs the main queue on
  another thread, where the main actor's isolation check traps.

## Consequences

Rough numbers from release builds on a machine with another build at about 110% CPU: W2 first rows
11–13 ms, the full listing 285–340 ms, 200–236 ms of it in the lister. Over the `Listing` build,
the service adds about 22 ms for 100k entries, about 15 ms of it the byte-exact repeat check. The
B9 case reads 42.3 MB. Ten W2 loads at once took 1.5–1.9 s to the last first rows and 2.0–2.6 s
to the last full listing. Spike S4 measured 0.7 s and 0.9 s on an idle machine.

On a share whose first read returns few entries, first rows wait for the second read. A load
cancelled while it runs stops at its next batch, so a call blocked on a hung share still holds its
slot until the call returns. M2.1's per-volume limits address that.
