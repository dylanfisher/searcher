# 0029. Row movement: a cursor and an anchor by name, keys through the registry, clicks synced back

- **Date:** 2026-10-21
- **Status:** accepted

## Context

M1.2 adds the row movement keys (Home and End first and last row, Opt-↑/↓ and Ctrl-Shift-↑/↓ ten
rows, Fn-↑/↓ a page), Shift-↑/↓ to extend the selection, and Cmd-A. Until now the pane's
selection was a set of names, and ↑ and ↓ moved it only when one row was selected. Extending
needs to know where a range started and which end moves. `NSTableView` has its own selection
extension on Shift-↑/↓, and those keys reached it, since only keys with Command, Control or
Option were kept from it ([0027](0027-key-dispatch.md)). Clicks, Shift-clicks and Cmd-clicks also change the table's
selection directly. B6 (16 ms on W2) applies to each of these commands, and B10 (no stall over
50 ms) to everything on the main thread.

A first version held every selected name in a set and found their rows on each change. In a
release build on 100k entries, Cmd-A took 43 ms before drawing, and with everything selected each
folder change patch took about 75 ms on the main thread: 36 ms to drop missing names and 40 ms to
find the rows again. A download growing in the folder sends a patch every 0.1 s. A second
version made Select All cheap but still resolved on the main thread: a load landing after Cmd-A
took about 44 ms there (30 ms comparing the listings), a patch with half the rows selected by
name about 32 ms, and a click selecting half the rows 32–51 ms.

## Decision

- **Selection.** `Selection` holds its members, a cursor and an anchor, all by name, so the
  selection follows its entries through a re-sort or a folder change patch. The members are
  either `.only(names)` or `.allExcept(names)`. Cmd-A makes `.allExcept([])`, and a click that
  selects more than half the rows names the rows left out, so a large selection costs as much as
  the rows it leaves out.
- **No entry selected unseen.** `.allExcept` means every entry listed when the selection was
  made, not every entry there will be. The selection keeps that listing as a baseline. A patch
  reports the entries it added, found with one lookup each off the main thread, and they join the
  exceptions. A load is compared with the baseline by walking both listings' name orders side by
  side (`Listing.names(notIn:)`), one key comparison per entry with no lookup or hashing. A first
  batch excludes only what it adds, so entries still to come aren't excluded.
- **Rows resolved off the main thread.** The selection keeps its rows in the listing it was last
  resolved against or moved in, and the view reads them without finding any itself. Each new
  listing is made off the main thread, by a load, a patch or a sort, and the same worker resolves
  the selection against it, saying how the listing changed: the same entries (a sort), patched,
  or loaded, partly or completely. A patch and a complete load drop names the listing doesn't
  have. `ListingService.load` takes a `prepare` step that runs on the load's worker for each
  update. The main thread takes the resolved copy if the user hasn't changed the selection since
  the work started (`selectionVersion`). Names are looked up one by one when few are selected;
  past one in eight rows, where the review's W2 timings cross, every row is checked against the
  set instead.
- **A selection changed during the work settles off the main thread too.** When the user changed
  the selection while a load, patch or sort ran, the main thread shows the new listing with the
  current selection provisionally: it checks only the rows within a page of the cursor
  (`Selection.provisional`), so the change shows at once, and keeps the listing change as
  pending. A worker then settles the selection (`Selection.settled`) and the pane takes the
  result if neither the selection nor the state changed meanwhile; otherwise it settles the
  selection as it is then, one at a time. Moves on an unsettled selection work on the rows they
  change, as before, and keep those names as edits, applied over the members when it settles.
  Two pending changes combine: two patches add what both added, and any other pair counts as a
  load, compared with the baseline, where the later listing says whether a missing name is gone.
  `members` traps until the selection is settled, so nothing reads half-resolved names.
- **The table draws a full-width selection.** `NSTableView`'s `.automatic` style is `.inset`,
  which rounds a selection's corners where it meets unselected rows and updates each changed
  row's neighbors to do it (`_updateAdjacentSelectionWiewsForRow:` in a sample, called once per
  changed row). In a release build on 100k rows, `selectRowIndexes` from one row to all took
  13–15 ms with it and 0.2 ms with `.fullWidth`; shifting 50k selected rows by one, 6–8 ms and
  0.01 ms. The table keeps its own selection, so clicks, Shift-clicks and VoiceOver work as
  before.
- **A new listing of the folder on screen refreshes the rows in place.** A patch, a sort or a
  reload of the folder shown tells the table the row count (`noteNumberOfRowsChanged`) and
  fills the cells of the row views it already has, instead of `reloadData`, which drops them
  and lays out and draws a new screen of rows. In a release build on 100k rows, the main
  thread's pass that lands a patch went from about 23 ms to 1.5 ms. A new folder still reloads.
  This replaces the one `reloadData` per listing that [0006](0006-concurrency-shape.md) describes
  for a folder already on screen.
- **Moves.** A plain move puts the cursor on the target row and selects it alone, collapsing a
  multi-row selection. An extending move keeps the anchor and changes the range from the anchor to
  the cursor, as `NSTableView` and Finder do. Rows the old range covered and the new one doesn't
  are deselected, rows the new one adds are selected, and rows selected outside both, such as
  Cmd-clicked ones, stay selected. A move touches only the rows that change, whatever the size of
  the selection. A missing anchor falls back to the old cursor, then to the target. With no cursor
  a move down starts at the first row and a move up at the last. A cursor the listing doesn't
  have yet (the folder just left, while the parent's first rows show) moves nothing.
- **Keys.** Every row movement key, Shift-↑/↓ included, is a registered command in
  `SelectionCommands`, so `ListingTableView.keyDown` runs it and `NSTableView` never sees it.
  Cmd-A is registered as Select All, which the Edit menu's item runs. `KeyChord.Key` gains
  `pageUp`, `pageDown`, `home` and `end`, named Page Up, Page Down, Home and End: Fn-↓ types the
  Page Down character and Fn-→ the End one, and the keys of a full keyboard give the same
  chords. Opt-↑/↓ and Ctrl-Shift-↑/↓ are both chords of Move Up/Down 10 Rows (Dylan,
  2026-10-24: "add the keyboard shortcut for jumping up/down 10 files (option+up or
  option+down)"), which took Opt-↑/↓ from Select First/Last Row; those moved to Home and End.
  Cmd-Opt-↑ and Cmd-Opt-↓ are second chords of Select First/Last Row (Dylan, 2026-10-25: "add a
  shortcut for cmd+opt+up/down to go to very top or very bottom"). Cmd-↑ is Enclosing Folder and
  Cmd-↓ is Open; the chords differ in the Option flag, so the registry never confuses them, and
  nothing else used Cmd-Opt-↑/↓ (the tiling keys use Cmd-Opt-Shift-arrows). A pane's table and
  the sidebar ([0089](0089-sidebar-key-routing.md)) both pass a chord a command takes to the
  pane. Like Home and End they select by key, so a column opens after the pause ([0094](0094-column-open-delay.md)).
  Unbound Shift-only keys still reach `super`. Shift with Page Up, Page Down, Home, End, ← and →
  was checked against the table and moves nothing. `allowsMultipleSelection` stays on, for clicks and for showing the pane's ranges.
- **Page.** A page is `Pane.visibleRowCount` rows, the whole rows that fit below the column
  header. `ListingViewController.viewDidLayout` sets it, subtracting the header's overlap with
  the clip view, since the rows scroll under the header. A pane too short for one row moves one.
- **Scrolling.** When the cursor moves without a reload, the view scrolls its row into view in
  the same pass, so the frame that shows the new selection shows the row. After a reload it
  scrolls to the cursor a pass later ([0025](0025-sort-off-main.md)), and only when the reload
  shows a new folder or a new sort. A patch that shifts the selected rows leaves the view where
  the user scrolled it. Cmd-A keeps the cursor, so it doesn't scroll.
- **Clicks.** `tableViewSelectionDidChange` reports a selection the table made itself to the pane:
  the selected rows as members, the clicked row as the cursor (or, with no click, the row the
  table selected last), and the anchor on the cursor. A Shift-click, read from the current event's
  modifier flags, keeps the pane's anchor instead. The table's rows go to the pane as they are
  (`Pane.select(rows:cursor:anchor:)`), and the selection holds them unnamed until a worker
  names them, so the main thread builds one name, the cursor's. A worker that resolves the
  selection for a load, patch or sort names them first.
- **Patched names.** A patch counts an entry as added only if the listing before the whole batch
  lacked it, so a name removed and written again in one batch stays selected under Select All,
  as it does in a selection by name.
- **Bench.** The UI bench's launch that presses ↓ then times, on W2, 200 presses each of End
  and Home alternating, Ctrl-Shift-↓, Fn-↓ and Shift-↓, then 100 Cmd-A presses, each after an
  untimed ↓, then 100 folder change patches and 20 reloads landing with every row selected. The
  keys go through `window.sendEvent` like ↓. Each patch changes an entry's size in memory and goes
  through `Pane.apply`, the path the folder monitor's patches take, so it makes no file-system
  call. A reload lists W2 again on the load's worker, as any reload does; its span runs from the
  start of the main run loop pass that takes the listing in to the frame, so it times the main
  thread's share and not the listing. Then come 100 patches that each add an entry right after
  the first row under Select All, 100 selection changes to half the rows through the table as a
  click makes them (the window isn't active, so it takes no real clicks), 100 patches that each
  land after a Shift-↓ sent while they run, with half the rows selected, and 20 reloads with
  Cmd-A pressed on the first batch. The last two are timed from the start of the pass that takes
  the result in, like a reload, and each waits for the selection to settle before the next.
  Each case checks where it leaves the selection, and each is its own field in `UIBenchRecord`
  and its own B6 case in the report.

## Alternatives considered

- **Keep `NSTableView`'s Shift-arrow handling and read its selection back.** Rejected: the table
  keeps its own anchor, which the pane's moves don't set, so the two would disagree after a key
  move, and the pane couldn't time or test it.
- **Turn `allowsMultipleSelection` off.** Rejected: it also stops the pane from showing a range,
  and it removes Shift-click and Cmd-click.
- **Extend to the range alone, dropping rows outside it.** This was the first version. Rejected:
  the key table builds commander behavior on top of normal macOS selection, and Finder and
  `NSTableView` keep the other rows.
- **Keep a set of every name for Select All, and only make the rest cheaper.** Rejected:
  building the set took 8 ms on W2, and every patch would still have to find 100k rows again.
- **Let `.allExcept` take in entries that arrive later.** Rejected: a command on the selection
  would act on files the user never saw.
- **Find a load's new entries by hashing the baseline's names.** Rejected: walking the two name
  orders compares keys and allocates nothing.
- **Page by the visible count minus one, keeping a row of context.** Rejected: nothing in the
  key table asks for it, and the cursor would land on the last visible row instead of the next
  page.
- **Resolve on the main thread when the selection changed during the work.** This was the M1.2
  version. Rejected: in a release build on 100k W2-like names it took 105–119 ms when Cmd-A on
  the first batch met the full listing, and 47–70 ms for a patch or sort landing after Shift-↓
  with half the rows selected.
- **Hold the new listing back until the selection is resolved against it.** Rejected: loads,
  patches and sorts each read the state the moment they land, to start the next sort or patch
  or relist, and the order in which states replace each other would change.
- **Replay the user's moves on the worker's result.** Rejected: a move by rows means something
  else in a re-sorted listing, and Cmd-A on a first batch still needs the full comparison.
- **Draw the selection from the pane in the row views and keep the table's selection small.**
  Rejected: the full-width style removes the cost with one line, and a selection the table
  doesn't hold would need its own click handling and VoiceOver reporting.
- **Diff the index sets and change only the rows that moved.** Measured: with the inset style,
  deselecting one row and selecting another under 50k selected rows took as long as replacing
  the set, so the cost isn't in the size of the change; with full width neither costs anything.
- **Keep naming a click's rows on the main thread.** Rejected: 13–15 ms for half of 100k rows,
  plus a comparison of the old and new name sets in `Pane.set`.

## Consequences

`Selection.rows(in:)` trusts the rows it was last resolved to, so code that hands a selection a
different listing must resolve it first; `Pane` is the only place that does. Tests guard the
large-selection paths with `Selection.work`, a task-local count of names looked up, built,
walked or compared, and `Pane.mainSelectionWork`, the part of it done on the main thread, not
with timings. Both exist in debug builds only, and the tests that read them are compiled only
there, so `swift test -c release` builds.

The worker resolves the selection the load, patch or sort started with. A patch that lands
during a load changes the selection without the user, so the load's copy can be older than the
one shown; such a patch makes the pane list the folder again once the load ends, and that load
starts from the patched selection.

Until a provisional selection settles, rows more than a page from the cursor don't show as
selected, so rows the user scrolled to away from the cursor can show unselected for the few
frames a settle takes (a walk of W2 is about 33 ms). Opening the selection in that time settles
it on the main thread first. While a key repeats faster than a settle, each settle is dropped
and started again, and the selection stays provisional until the key is released. A name a
pending patch removed and a later one wrote again counts as never removed, as it does within
one batch.

The full-width style changes the look: the selection spans the row from edge to edge with
square corners, as tables did before macOS 11, instead of an inset rounded highlight.

Measured with `./scripts/bench --ui`, alternating with the M1.2 commit 1fad9b3, with
`--check-idle` saying idle before and after each run. B6 p95s in ms; the cases after reload
are new, so the baseline has none:

| B6 case | 1fad9b3, 3 runs | This change, 3 runs |
|---|---|---|
| ↓ | 10.15, 9.27, 9.26 | 9.43, 9.02, 10.42 |
| Opt-↓/↑ (then first and last row; now Home/End) | 10.25, 10.00, 9.01 | 13.52, 14.14, 10.44 |
| Ctrl-Shift-↓ | 8.85, 9.12, 10.51 | 9.70, 12.08, 8.66 |
| Fn-↓ | 9.47, 10.09, 9.42 | 11.13, 10.47, 10.11 |
| Shift-↓ | 9.04, 9.12, 9.08 | 10.23, 10.84, 9.01 |
| Cmd-A | 9.87, 10.14, 10.87 | 7.57, 8.39, 7.34 |
| Patch, all selected | 42.50, 44.17, 42.27 | 8.61, 9.27, 8.79 |
| Reload landing, all selected | 42.91, 42.90, 41.82 | 10.39, 12.27, 9.10 |
| Patch adding a row, all selected | — | 13.95, 10.82, 14.29 |
| Click selecting half | — | 5.79, 7.30, 8.00 |
| Patch landing after Shift-↓ | — | 1.74, 1.68, 1.78 |
| Load landing after Cmd-A on first batch | — | 10.34, 9.86, 9.85 |
| Stalls over 50 ms | 0; 15, all in launch; 0 | 0, 0, 0 |

A pane's `visibleRowCount` is 0 until the view first lays out, so a page move before then moves
one row. The cursor can sit on a row that isn't selected (after a Cmd-click that deselects it),
and a plain move goes on from there. A Shift-click selects the range `NSTableView` computes from
its own anchor, which can differ from the pane's after a key move; the pane takes the rows the
table shows and keeps its anchor for the next Shift-arrow. Drag selection and Shift-click are
untested by hand.
