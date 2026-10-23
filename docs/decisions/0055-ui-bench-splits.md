# 0055. UI bench with splits: built with the tiling keys, unfocused redraws fail the run

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.7 asks the UI bench to time ↓ in the focused pane of a two-pane split and of a 4-pane grid,
every pane on W2 (B6), and open → first rows frame in the focused pane while ten panes load (B2
W2), with the stalls of that load reported (B10). The unfocused panes must not redraw during ↓,
with the count in the log. [0048](0048-pane-load-priority.md) times the service side of ten
loads with the focused one asked last; [0054](0054-tabs-in-window.md) made the window show a
workspace's split tab, and noted that every command now runs the window's update, ↓ included.
[0050](0050-ui-bench-scenarios.md) added column keys to the CI run's first launch and a
scenario to run them alone. Gaining the focus lists a pane's folder again (0048), so moving the
focus while building a grid starts loads that land later.

## Decision

- **The splits are made the way a user makes them.** The bench sends Cmd-\ and Cmd-Shift-\ to
  the window, and Cmd-Opt-Shift-arrows to move the focus, so each runs through the table, the
  command registry, `TilingCommands`, `Tab` and the window's update. Each step splits the largest
  pane with room, along its longer side; the focus keys that reach it are found by pressing them on
  copies of the tab's `Layout`. Two panes, then a 2 × 2 grid, then ten panes (a 4 × 2 grid
  with two of its panes split again) fit the 900 × 600 window at `Layout.minimumPaneSize`.
- **No load is left running before a timed run.** After each split the bench waits for every
  pane's complete listing, and after the focus keys for each pane they focused to land the
  listing that gaining the focus started. Before the ↓ presses it waits for a frame after which
  the window has nothing to draw.
- **Where they run.** ↓ in two panes and in the grid run in the CI run's first launch, after the
  column keys, which they switch back to list view with Folders First off. Every launch then
  ends by opening W2 in ten panes: every pane goes to W1, the window is split to ten, and the
  nine unfocused panes then the focused one navigate to W2 in one pass, timed to the frame with
  the focused pane's first rows. That is one B2 sample per launch, 20 per run, as `open W2`
  has. Like every span, it ends at the first commit after which the whole window has nothing
  to draw, not the focused pane alone, so the other nine panes' drawing can fall inside it. The
  sample is the longest a user could wait for the focused pane's rows, which errs toward a
  miss. `--ui --scenario splits` runs the same on W2 in one launch, with the ten-pane open
  repeated `UIBenchOptions.tenPaneOpens` (20) times.
- **The ten-pane load's stalls are counted on their own line.** The timed span is `ten-pane open`;
  the rest of the load, until every pane holds its complete listing, is an untimed span
  `ten-pane load`. The report prints the stalls filed under either, reported only, as 0022
  decided for runs that open no share.
- **An unfocused pane that needs drawing during ↓ fails the launch.** A run loop observer at
  order 0, before AppKit draws and Core Animation commits, checks each unfocused pane's view
  tree, skipping hidden views, for a view that needs display, in every pass of the ↓ run. The
  launch prints the count for each unfocused pane and exits 1 if any is non-zero, as it does
  when a key leaves the wrong selection. The window has drawn everything before the run starts,
  so a count above zero is a redraw the presses caused.
- **CI.** No change to the job: `./scripts/bench --ui` runs the new cases, and `compare-ui`
  judges them. As in 0050, each new case is report-only until its p95 holds within 10% for
  three runs on the branch ([0023](0023-ui-bench-in-ci.md)). The redraw check is not
  report-only: a launch that fails it leaves the record short, which fails the job.

## Alternatives considered

- **Build the layouts with `Tab.split` and `Tab.focus` directly** — rejected: the window wouldn't
  update until something else made it, and the bench would skip the key path and the window's
  update that 0054 says ↓ now pays for.
- **Count draws by swapping in a counting `draw(_:)`** — rejected: each kind of view draws through
  its own override, and a runtime swap in the bench can't be checked by a unit test.
  `needsDisplay` is what `FrameCommitTimer` already ends a span on.
- **Report the redraw count only** — rejected: nothing else would catch a redraw in an unfocused
  pane, and its cost scales with the number of panes.
- **Ten-pane opens all in the first launch** — rejected: that launch already presses more than
  2,000 keys inside the 120 s launch timeout. One per launch spreads the cost and matches `open W2`.
- **Open the ten panes from the temporary folder instead of W1** — rejected: `open W2` starts
  from W1, and the two B2.W2 cases should differ only in the pane count.

## Consequences

Every CI launch takes about a second longer: nine splits on W1 and ten W2 listings. The first
launch also lists W2 for each pane the split cases make and each pane the focus keys pass.

The redraw check sees only views marked for display before AppKit's display pass; a view
invalidated during layout in that pass draws without being counted. A check that misses that
case lets such a redraw through; it can't fail a run that has none.

The focused pane in the ↓ runs is always a pane the last split made, so it starts with no
selection, as the single pane's ↓ does.
