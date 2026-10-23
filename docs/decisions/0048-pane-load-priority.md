# 0048. Pane load priority: focused, visible, hidden, read when a load starts

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.4 asks that focusing a pane moves its waiting load to the front, that panes in tabs that
aren't selected load after the ones on screen, and that a closed pane gives back its memory
(B2 W2 100 ms for the focused pane while ten W2 panes load; B9 per pane). `ListingService`
already let a `.focused` load start before every waiting `.normal` one
([0006](0006-concurrency-shape.md), [0041](0041-column-model.md)), but a load's priority was
fixed when it was asked. A pane that gained the focus kept its place, and so did a column
([0041](0041-column-model.md) rejected requeueing: the service couldn't tell a waiting load from
a running one). Loads wait for their volume and per-volume reads ([0038](0038-slow-volumes.md));
the workspace model holds tabs and panes ([0042](0042-workspace-model.md)) but nothing told a
pane whether its tab was selected.

## Decision

- **One priority, three levels.** `ListingLoad.Priority` is `hidden < visible < focused`;
  `.normal` became `.visible`. The queue picks the highest priority among loads whose volume is
  known and has a read to spare, then the earliest asked. The per-volume limits of 0038 are
  unchanged: a hidden load on a free volume starts before a visible one waiting on a busy share.
- **Priority is read when the queue picks.** `ListingLoad.priority` is settable, under the
  load's lock, and the queue reads it each time it chooses the next load. Changing it moves a
  waiting load and does nothing to a running one, so nothing is restarted or requeued and a
  load is never read twice.
- **The pane sets its loads' priority.** `Pane.loadPriority` is focused if `isFocused`, else
  visible if `isVisible`, else hidden. A change to either moves the pane's current load and a
  pending `goToFolder`. A pane in column mode passes `isVisible` to its columns, and a new
  column takes the owner's. A trail moving the focus between columns now moves the newly
  focused column's waiting load to the front, which 0041 left in place.
- **The workspace tells the panes.** `Workspace` keeps the selected tab's panes visible and every
  other tab's hidden, and tells the selected tab's focused pane it gained the focus
  (`didGainFocus`) and the pane that had it that it lost it (`didLoseFocus`). It does this when
  a tab is added, selected or closed, and when the selected tab's focus moves: `Tab` calls its
  `onFocusChange` after `focus`, `split` and a `closePane` that leaves the tab open. The
  workspace reaches the service only through these pane hooks.
- **A closed pane frees its listing and watch.** `Pane.close()` already cancels the load and
  stops the monitor, which closes its descriptor; once the tab drops the pane nothing else holds
  it, so its `Listing` goes with it. A test pins both with a weak reference and the descriptor.

## Alternatives considered

- **A second queue or a separate tab-level priority** — rejected: two orderings would have to
  agree on every pick. One comparable priority covers both.
- **A service call that requeues a load at its new priority** — rejected: the queue already reads
  each load's priority on every pick, so moving the load in the list adds nothing, and it would
  have to find out whether the load had started.
- **Restart a waiting load at the new priority** — rejected: a restarted load reads its volume
  again, and on a share that blocks.
- **Leave visibility and focus to the view (M3.5)** — rejected: the model wouldn't be testable
  without windows, and every view would have to repeat the same bookkeeping.
- **Clear a closed pane's state so its listing goes even if a view still holds the pane** — not
  now: the pane is freed with its tab entry, and a view that keeps a closed pane is the bug.

## Consequences

`didGainFocus` lists the folder again unless a load is running, so selecting a tab or moving the
focus between panes re-lists the newly focused pane's folder, as focusing a pane already did.

Nothing ages a waiting load, so a hidden tab's loads can wait for as long as four or more
visible panes keep listing their folders again. Each pane has at most one load at a time, so
the wait ends once the visible panes stop re-listing.

The B9 budget for ten panes (≤ 10 × 60 MB, and within 10% of the start after closing nine) isn't
benched in this step. Only the release is tested: a closed pane is freed with its listing and
its watch descriptor is closed.

The focused load is asked last in the ten-pane bench case, so its volume is read last. With
every slot open to every priority, four visible loads whose volumes were read first took all of
them, and the focused load waited about one full W2 load (734 ms against the 100 ms of B2.W2).
The service now keeps the last of its `mostRunningLoads` slots for a `.focused` load: a hidden
or visible load starts only while fewer than `mostRunningLoads - 1` are running, a focused one
takes any free slot. The focused load starts at once behind three running loads, at the cost of
one fewer concurrent background load (three where there were four). A load whose priority is
raised to focused while it waits asks the service to start waiting loads, since a free slot
may already be waiting for it. Nothing preempts a running load, so a focused load asked while
three loads and another focused one run still waits. The case
`open W2 ×10, focused asked last: focused first rows` measures this, against B2.

For M3.5, which builds the window on `Workspace`:

- Make every pane through a `Tab` in the window's `Workspace`; the workspace sets `isVisible`
  and calls the focus hooks for tab and pane changes, so the views must not call them for those.
- Calls to `didGainFocus` and `didLoseFocus` for the window becoming or ceasing to be key stay
  with the window, on the selected tab's focused pane.
- Release a pane's view and controllers when `closePane` or `close` reports it closed: the
  closed pane must not outlive its tab entry, or its listing stays in memory.
- The ten-pane bench case, `open W2 ×10, focused asked last: focused first rows`, measures the
  service side; the frame side is the UI bench's.
