# 0050. UI bench scenarios: column keys in the CI run, share scenarios by hand

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M2.11 adds column view to the UI bench (B6 on W2, in CI) and three runs on a share that only
Dylan's NAS can serve: cold opens (B3), revisits to cached rows (B4) and a column walk with a
stall count (B10). [0022](0022-ui-bench-mode.md) made the UI bench one shape of launch, and
[0023](0023-ui-bench-in-ci.md) judges the CI run's record against a history of exactly 20
launches. [0046](0046-column-view.md) names the cost this has to measure: each folder row
passed by ↓ in a column makes a column controller and a table and starts and stops a folder
monitor. W2's folders are 1% of its 100k entries, all empty, scattered among the files by name.

## Decision

- **Column keys run in the CI run's first launch**, after the filter keys, so CI times them with
  no change to its job: Folders First on (so W2's ~1,000 folders are its first rows), the pane
  switched to column view, the first column's first row selected, then 500 ↓ presses, each
  moving onto a folder and opening its column, then → and ← alternating 100 times each. Each
  is its own B6 case. W2's folders are empty, so → moves the keys into an empty column.
- **`--scenario <name>`** with `--ui` runs one launch of one scenario: `column-keys` (the same
  column cases alone, on W2), `cold`, `revisit` or `column-walk`. The last three need `--path`,
  which has no default; without it the runner exits 1 saying so. An unknown name exits 1 listing
  the names, and `scripts/bench --help` prints them with what each times. The names are
  `UIBenchOptions.Scenario`, in Base, the one place the runner and the app both read.
- **One launch and its own file.** A scenario writes `.build/bench-ui-<name>.json`, so it never
  stands in for the 20-launch record `compare-ui` judges. One launch is enough: column keys
  give 700 samples, and a cold folder is cold only once.
- **Cold and revisit open the `--cold-children` subfolders.** The runner picks them with
  `ColdChildren.children(of:)`, the code `--cold-children` uses, listing only the parent, and
  passes the paths to the app. The app times open → first rows frame for each (B3). Revisit
  opens each untimed, waits on the cache's flush, then opens each again from the parent, timed to
  the frame with its cached rows (B4); its own rows showing first fails the run, since that
  means the folder isn't on a network volume or the cache didn't keep it. Only a revisit launch
  has a cache, in memory with no store, so no other span shows cached rows.
- **Column walk fails on a stall after the launch warm-up.** It opens `--path` in column view
  with Folders First on, selects the first row, presses ↓ to the last folder among the first
  100 rows (each folder row opening a column that lists from the share), → into that folder, ↓
  through up to 100 of its rows once they land, and ←. Stopping on a folder rather than on the
  100th row means a trailing file, such as a cover image, doesn't end the walk. Each key is a
  B6 sample. Any stall after the launch warm-up fails the run against B10 ("never > 50 ms"),
  since this run is on a share, which is what B10 is about. Stalls in the launch, up to the
  window showing and `LaunchWarmup` ending (a "launch warm-up" span), belong to B1 and open no
  share. The CI run and the other scenarios still report stalls only, as 0022 decided.

## Alternatives considered

- **Column keys as a scenario only, with a CI job step for it** — rejected: CI would need a
  second record and history for one more set of B6 cases, and the CI run already opens W2.
- **A W2 variant whose folders have rows** — rejected: a new fixture changes what every W2
  budget measures; → into an empty column still times the focus change and the keys moving.
- **The app picks the cold subfolders from the pane's rows** — rejected: the pane sorts by
  Finder's name order and `--cold-children` by byte order, so the two would time different
  folders under one meaning.
- **Judge every stall in column-walk** — rejected: a stall while the first window appears
  would fail a run about the share for a reason that has nothing to do with it.
- **Default `--path` to the NAS mount** — rejected: a path under /Volumes that isn't mounted, or
  is another share, would time the wrong thing or hang.

## Consequences

The CI run's first launch takes a few seconds longer (W2 listed again for the first column, then
700 keys), and its three new cases are report-only until they have three steady runs (0023).
Revisit opens the same subfolders as cold, so running it before cold on the same mount leaves
cold with nothing never-opened; run cold first, or remount between. The cold subfolders are the
first 20 by name each time, so a second cold run needs a remount, as `--cold-children` does.
