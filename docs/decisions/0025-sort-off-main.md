# 0025. Sort off the main thread, scroll to the selection a pass later, no AppKit type-select

- **Date:** 2026-10-21
- **Status:** accepted

## Context

B10 says the main thread is never blocked for more than 50 ms. Decision
[0024](0024-launch-warmup.md) left one stall in the idle UI bench: launch 1's sort change on W2,
57–71 ms, the only launch with a selection (row 500, after 500 ↓ presses). Timed inside the
pass, it was `Pane.setSort` sorting 100k entries on the main thread (16.8 ms), `reloadData`
(6.1 ms), `scrollRowToVisible` to the selection's new row far down the list (14.9 ms), then the
drawing. Dylan's debug dev build sorted in 160–179 ms per stall. His dev session also stalled
for 629 and 495 ms on W2 in AppKit's type-select, which makes a row view for each row it checks
when a letter key reaches the table.

A sort change can race the pane's other work: folder changes arrive as patches or relists
([0021](0021-one-pane-window.md)), a load can land, and the user can click another header before
the first sort ends.

## Decision

- **Sort.** `Pane.setSort` takes the new sort at once, so the header shows it and later loads
  are asked for it, and sorts a copy of the rows on a global queue. The result is applied on the
  main actor only if the pane's `stateVersion` and sort are still the ones it started from.
  Whatever changed either of them started its own sort if its rows needed one: `setSort`, a
  landed patch, and a landed load all call `startSortIfNeeded`. So the last request wins, and a
  load that lands during a sort is kept and sorted in turn. The selection is a set of names, so
  it follows its entries to their new rows.
- **Patches wait for a sort.** Folder change patches that arrive while a sort runs wait, and are
  applied to the rows the sort lands. A landed patch changes the state, which drops the running
  sort and starts another; with FSEvents reporting every 0.1 s, a folder that keeps changing (a
  growing download) would otherwise hold off a sort slower than that for as long as it changes,
  and the debug build's W2 sort takes 160–179 ms. A patch already running when the sort starts
  still lands first and restarts the sort once.
- **Loads in the old sort.** A load that started before `setSort` arrives in the old sort. It
  is shown as it arrived and sorted off the main thread like a sort change, where it was
  re-sorted on the main thread before.
- **Main thread check.** `Listing.sort` traps on the main thread, as `Listing.init` and
  `Listing.update` already did, so an O(n log n) sort on the main thread fails loudly.
- **Scroll.** When `ListingViewController` reloads the rows and a single selected row needs
  scrolling into view, it scrolls in the next run loop pass, reading the selection again then.
  Scrolling in the reload's pass made the table lay out a screen of row views on the spot,
  15–18 ms in a release build; a pass later the scroll took about 4 ms. A selection change
  without a reload (↓) still scrolls at once, so B6 is unchanged.
- **Type-select.** `ListingTableView` turns off `allowsTypeSelect`. M1.7 builds type-to-select
  on the pane's listing.
- **Bench.** The UI bench's sort change now waits for the pane to show rows in the new sort, then
  times that frame, since the header's frame no longer holds the sorted rows.

## Alternatives considered

- **Hold a sort request until the running sort lands** — rejected: a superseded result is
  dropped when it lands, which costs one wasted sort and no queueing state.
- **Let patches run during a sort, restarting it** — rejected: see Patches wait for a sort.
- **Patch the old rows and the sorted copy both** — rejected: the patch work doubles for every
  change during a sort, to show a change one sort earlier.
- **Hold a load in the old sort until it is sorted** — rejected: the load's end, its follow-up
  relist and the selection filter would wait on the sort. Its rows show in the old order for
  the length of a sort, as a sort change's do.
- **Scroll with `NSClipView.scroll(to:)` in the reload's pass** — tried: it cost the same
  18 ms, since the table lays out row views for any change of its visible rect.
- **Keep type-select and give it `typeSelectStringFor`** — rejected: AppKit still walks the rows
  on the main thread, and M1.7 replaces it.

## Consequences

Measured with `./scripts/bench --ui`, alternating with the baseline 7578795, `--check-idle`
saying idle before and after each run:

| | Baseline, 3 runs | Change, 3 runs |
|---|---|---|
| B1 p95 | 89.0, 82.1, 84.3 ms | 86.7, 95.7, 85.3 ms |
| B6 p95 | 9.11, 9.53, 9.19 ms | 8.85, 8.91, 8.78 ms |
| B8 p95 | 34.2, 34.7, 35.1 ms | 34.9, 34.3, 34.7 ms |
| Launch 1's sort change | 54.6, 55.2, 55.5 ms, one stall each | 53.5, 54.4, 54.4 ms, no stall |
| Other stalls | none | one of 55.1 ms in launch, in one run |

B8 before and after are comparable: both end on the frame that shows the sorted rows. Launch
1's sort change still takes about 54 ms from the header change to the frame, but it is
now spread over the off-main sort and two shorter passes. The launch stall is the first frame's
drawing that [0024](0024-launch-warmup.md) describes, which this change doesn't touch.

After a sort change the header shows the new column for the length of the sort, 8–17 ms on W2
in a release build, before the rows follow. After a reload that moves the selection, the first
frame can show the rows at the old scroll position, and the next one scrolls to the selection.
A folder change during a sort shows when the sort lands, not before. Each sort holds a second copy of the row order, 400 KB for 100k entries, until it lands.
