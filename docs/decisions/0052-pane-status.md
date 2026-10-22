# 0052. Pane status: one delayed spinner and the slow or offline note at the end of the path bar

- **Date:** 2026-10-22
- **Status:** accepted

## Context

[0045](0045-cached-rows-first.md) gave a pane the `cachedRefreshing`, `slow` and `offline` states
and left showing them to M2.5. Until then a spinner sat over the list for `loading` and for
`slow` with no rows, shown at once, and in column view nothing showed
([0046](0046-column-view.md)). `LoadTimeouts.spinnerDelay` (150 ms) existed but nothing read it.
The note has to name the volume that stopped answering and say how old the rows are, and
Interface may not ask the file system for either. `Pane.rootVolumeName` is always the volume at
`/` ([0026](0026-path-bar.md)), so it can't name a share. [0049](0049-volume-events.md) takes a
pane offline when its volume unmounts, which can happen before any listing update has named a
volume. M2.5 also adds a deny list for file-system calls in Interface and the app to
`scripts/arch`.

## Decision

- **One spinner per pane, in the path bar row.** `PaneStatusView` sits after the path bar, in its
  row: a small spinner, and before it a one-line note that truncates first and takes at most 60%
  of the row. The spinner over the list is gone; the access explanation and the error line stay
  over the list.
- **When it spins.** While the state is `loading`, `partial`, `cachedRefreshing` or `slow`, once
  `LoadTimeouts.spinnerDelay` has passed on an injected clock since the state went in flight.
  Moving between in-flight states keeps the wait running. `offline` doesn't spin: the load keeps
  going, but the note says the app stopped waiting.
- **The note.** `slow` says "music is slow to answer.", `offline` "music is offline.", then
  "Listed 5 minutes ago." for dated rows, "Showing part of the folder." for a first batch, and
  nothing for no rows. Under a minute the rows were "Listed just now." The age counts whole
  minutes from the injected date, and the note is written again each time the rows turn a
  minute older, timed from when they were listed. `PaneStatusText` holds every string and the
  spinner's VoiceOver label, and formats the age in English, the language of its sentences,
  whatever the system's language.
- **The volume's name.** `ListingService` names the folder's volume on the load's thread from the
  mount table it already reads without asking any volume (`getmntinfo` with `MNT_NOWAIT`): the
  last component of the longest mount point holding the path, network or local, so a hung
  external disk is named too. For a path whose longest mount point is `/`, it is the root
  volume's name; a path is placed by its text, so a firmlinked path such as `/Users` is on the
  root, not on the Data volume behind it. `slow`, `gaveUp`, `failed` and `volumeGone` carry it as `volumeName`, and `Pane` keeps the
  last one. `failed` carries it too because an `unreachable` failure takes a pane offline.
  `volumeGone` names the volume the service remembered, since the mount table no longer has it.
  A pane whose volume unmounts takes the name from the mount point `VolumeEvents` reports, and
  the path bar stays as it was until an update brings the root volume's name.
- **Column view.** The path bar belongs to the owner pane and shows the focused column's folder,
  so the status view shows the focused column's state too. Each column's own spinner is still to
  come (M2.8).
- **Nothing on the main thread waits for a share.** The test drives a pane view controller over
  a lister that never returns through the spinner, slow and offline, and checks that no read,
  no volume read and no mount table read ran on the main thread. It doesn't time the main run
  loop: B10's timing is the UI bench's (M2.11's share scenarios) and M2.12's.
- **The deny list.** `scripts/arch` fails on `FileManager`, `[rR]esourceValues`,
  `icon(forFile:` and `icon(forFiles:`, `statfs`, `fstatfs`, `getattrlist`, `getattrlistbulk`,
  `displayName(atPath:`, `Data(contentsOf:`, `NSData(contentsOf:` and `NSData(contentsOfFile:`,
  `String(contentsOf:` and `String(contentsOfFile:`, `NSImage(contentsOf:` and
  `NSImage(contentsOfFile:`, `getResourceValue(`, `FileHandle` and `checkResourceIsReachable` in `Sources/Interface`
  and `Sources/Searcher`, with no allowlist. It matches each file whole, so a call split across
  lines is caught, and skips comment lines. `FileHandle`'s standard streams are allowed: the UI
  bench reports its failures on standard error, a pipe, not the file system. Bare `stat` and
  `lstat` aren't listed; the words are too common. Each rule has a fixture in
  `scripts/arch-fixtures/`; the script checks every rule against its fixture before checking
  `Sources`, checks that every fixture has a rule, and fails when a folder it scans is missing.

## Alternatives considered

- **Keep the spinner over the list for a folder with no rows, and add the bar's for a refresh**
  — rejected: two spinners with two timers in one pane, and the plan places the pane's spinner
  in the path bar.
- **Name the share by `Pane.rootVolumeName`** — rejected: that is always the volume at `/`, so a
  pulled NAS would read "Macintosh HD is offline."
- **Take the name from the path's text under `/Volumes`** — the first version. Rejected: a share
  mounted elsewhere, such as under `/net`, got the startup volume's name.
- **Read the folder's volume with `statfs`** — rejected: it blocks on a share that stopped
  answering, and a path through a firmlink would read as "Data".
- **Name only network volumes from the mount table** — the second version. Rejected: a hung
  external or exFAT disk read "Macintosh HD is slow to answer."
- **Time the main run loop with `StallWatchdog` at B10's 50 ms** — the first version. Rejected:
  other tests share the test process's main thread and the other test targets' processes keep
  it off a core, so it failed one or two runs in six, and a filter strict enough to pass also
  let a 300 ms sleep in the status view through.
- **The system's locale for the age** — rejected: "music is offline. Listed vor 5 Minuten."
- **A note written again a minute after it appeared** — rejected: rows listed 90 s before would
  say "1 minute ago" until 150 s.

## Consequences

A folder that loads in under 150 ms never shows the spinner. An empty folder still loading shows
only the small spinner in the bar, not one in the middle of the list. A volume mounted at a
point whose last component isn't its name, such as a disk image mounted by hand under a
folder, is named by that folder. Each load reads the mount table once more, on its own thread.
Whether the main thread stays under 50 ms while a share hangs is measured only by the UI bench
and by hand.
