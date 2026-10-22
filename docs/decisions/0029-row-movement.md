# 0029. Row movement: a cursor and an anchor by name, keys through the registry, clicks synced back

- **Date:** 2026-10-21
- **Status:** accepted

## Context

M1.2 adds the row movement keys (Opt-↑/↓ first and last row, Ctrl-Shift-↑/↓ ten rows, Fn-↑/↓ a
page), Shift-↑/↓ to extend the selection, and Cmd-A. Until now the pane's selection was a set of
names, and ↑ and ↓ moved it only when one row was selected. Extending needs to know where a range
started and which end moves. `NSTableView` has its own selection extension on Shift-↑/↓, and those
keys reached it, since only keys with Command, Control or Option were kept from it
([0027](0027-key-dispatch.md)). Clicks, Shift-clicks and Cmd-clicks also change the table's
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
  the work started (`selectionVersion`), and otherwise resolves the current one itself. Names are
  looked up one by one when few are selected; past one in eight rows, where the review's W2
  timings cross, every row is checked against the set instead.
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
  `pageUp` and `pageDown`, named Page Up and Page Down: Fn-↓ types the Page Down character, and
  the keys of a full keyboard give the same chord. Unbound Shift-only keys still reach `super`.
  Shift with Page Up, Page Down, Home, End, ← and → was checked against the table and moves
  nothing. `allowsMultipleSelection` stays on, for clicks and for showing the pane's ranges.
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
  modifier flags, keeps the pane's anchor instead. The table's rows go to the pane with the
  selection (`Pane.select(_:atRows:)`), so nothing is looked up; only the names are built.
- **Patched names.** A patch counts an entry as added only if the listing before the whole batch
  lacked it, so a name removed and written again in one batch stays selected under Select All,
  as it does in a selection by name.
- **Bench.** The UI bench's launch that presses ↓ then times, on W2, 200 presses each of Opt-↓
  and Opt-↑ alternating, Ctrl-Shift-↓, Fn-↓ and Shift-↓, then 100 Cmd-A presses, each after an
  untimed ↓, then 100 folder change patches and 20 reloads landing with every row selected. The
  keys go through `window.sendEvent` like ↓. Each patch changes an entry's size in memory and goes
  through `Pane.apply`, the path the folder monitor's patches take, so it makes no file-system
  call. A reload lists W2 again on the load's worker, as any reload does; its span runs from the
  start of the main run loop pass that takes the listing in to the frame, so it times the main
  thread's share and not the listing. Each case checks where it leaves the selection, and each is
  its own field in `UIBenchRecord` and its own B6 case in the report.

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

## Consequences

`Selection.rows(in:)` trusts the rows it was last resolved to, so code that hands a selection a
different listing must resolve it first; `Pane` is the only place that does. Tests guard the
large-selection paths with `Selection.work`, a task-local count of names looked up and entries
walked or compared, and `Pane.mainSelectionWork`, the part of it done on the main thread, not
with timings. Both exist in debug builds only.

The worker resolves the selection the load, patch or sort started with. A patch that lands
during a load changes the selection without the user, so the load's copy can be older than the
one shown; such a patch makes the pane list the folder again once the load ends, and that load
starts from the patched selection. A selection the user changes while the work runs is resolved
on the main thread when the work lands, at the old cost: up to a walk of every row, or a
comparison of both listings after Select All.

A click still builds a name for each row it selects, or for each row it leaves out when it
selects more than half. On 100k synthetic ASCII names in an optimized build, a click selecting
half the rows took 1.8 ms; W2's mixed names cost more per name, and the UI bench doesn't time
clicks.

A pane's `visibleRowCount` is 0 until the view first lays out, so a page move before then moves
one row. The cursor can sit on a row that isn't selected (after a Cmd-click that deselects it),
and a plain move goes on from there. A Shift-click selects the range `NSTableView` computes from
its own anchor, which can differ from the pane's after a key move; the pane takes the rows the
table shows and keeps its anchor for the next Shift-arrow. Drag selection and Shift-click are
untested by hand.
