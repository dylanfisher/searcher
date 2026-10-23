# 0061. Split keys on T, splits that copy the pane, grid layouts, and Ctrl-Tab in the window

- **Date:** 2026-10-22
- **Status:** accepted

## Context

Dylan tried the app and asked for four changes (`tmp/behavior.md`, Tiling and Windows, tabs,
panes). A split opened a new pane on the focused pane's folder with nothing selected, scrolled to
the top, and listed the folder again ([0056](0056-open-in-new-tab.md): `Pane.newPane(at:)`).
Cmd-\ and Cmd-Shift-\, the split keys since [0044](0044-tiling-commands.md), clash with
1Password's autofill. He wants Sublime Text's layouts: keys that set the number of columns and
rows of an even grid. And Ctrl-Tab and Ctrl-Shift-Tab, the second chords of Show Next and Previous
Tab ([0054](0054-tabs-in-window.md)), did nothing in the app, though the tests that send them to
the table's `keyDown` passed.

## Decision

- **A split copies the pane.** `Pane.copy(takingFocus:)` makes the new pane as `newPane(at:)`
  does, at the same folder, with the same selection. When the source is in list mode with a
  complete listing, the copy starts with those rows and lists nothing; it lists the folder only
  when the source still has a load or a patch to land, and sorts its rows again when the source
  has a filter, which the copy doesn't take. A split's copy is focused at once, so gaining the
  focus doesn't list it either, as a pane moved to a new window isn't
  ([0057](0057-windows-and-tear-out.md)). Without complete rows the copy lists the folder, and
  its selection is resolved against the rows as they arrive, as any load's is. In column mode the
  copy's trail starts at the focused column's folder with its cursor selected, as before. New
  Tab, Open in New Tab and New Window keep `newPane(at:)`.
- **Scroll position.** The copy holds a weak `copiedFrom`. When the window makes the view of a
  pane a split or a grid key added to the selected tab, it scrolls the new list to the source
  list's clip view origin, after the layout view has placed it, and drops the scroll to the cursor
  that a new folder's list waits a pass to make. A list without rows yet takes the origin when its
  first rows show. Column view keeps its own scrolling.
- **Split keys.** Split Right is Cmd-Shift-T and Split Down is Cmd-Opt-Shift-T, beside New Tab
  (Cmd-T). Nothing else used them; Open Terminal is Cmd-Opt-T. Cmd-\ and Cmd-Shift-\ are unbound,
  and a test keeps them so.
- **Grid keys.** Cmd-Opt-1 to 4 set the columns, keeping the rows; Cmd-Opt-Shift-1 to 4 set the
  rows, keeping the columns. Both are in the Window menu, under Columns and Rows, after the
  splits. `Layout.makeGrid(columns:rows:in:)` builds the grid in the binary tree: a vertical run of
  rows, each a horizontal run of panes, with `equalize` giving every pane the same size.
  - **Counts.** `columnCount` adds a horizontal split's children's counts and takes the larger of
    a vertical split's; `rowCount` the other way round. That is exact for a grid, and for any
    other tree the most panes side by side, or stacked, along one line.
  - **Which panes stay.** The panes in reading order, by top edge then left edge, fill the slots
    in order. The focused pane is always kept, in the last slot when it would fall after it, and
    keeps the focus. The panes past the slots close as Close Pane closes them, stopping their
    loads and watches. New slots get copies of the focused pane, as a split does, last in the
    focus history.
  - Like a split, a grid key ends a zoom first, and does nothing when a pane would be under
    `Layout.minimumPaneSize`.
- **Shift and a digit.** A US keyboard types "!" for Shift-1. `KeyChord.candidates` already reads
  the key's own character for shifted punctuation ([0031](0031-view-settings.md)), so the table's
  `keyDown` finds Cmd-Opt-Shift-1. The menu item shows ⌥⇧⌘1, but in a test of
  `NSMenu.performKeyEquivalent` a "1" item with Shift did not match a "!" event, as "." didn't
  match ">" in 0031, and didn't match the Cmd-Opt-1 item either. The key then reaches the table,
  which runs the same command. The tests press the keys as a US keyboard sends them, through the
  table and through the menu's chord lookup.
- **Ctrl-Tab.** `NSWindow.sendEvent` takes Ctrl-Tab and Ctrl-Shift-Tab for the key view loop
  (`selectNextKeyView`, `selectPreviousKeyView`) before any view's `keyDown`, so the table never
  saw them; the menu items show only the first chord, Cmd-Shift-] and [. The window now offers
  each key press to its controller first. On a Ctrl-Tab chord whose command is a window command
  that is on, the controller runs it on the focused pane's table, wherever the keys are: the
  table, the filter field, the path bar or the tab strip. With one tab the command is off, and the
  key moves the key view as before. The test sends the keys to `NSWindow.sendEvent`.

## Alternatives considered

- **Share the listing between the two panes** — rejected: each pane patches, sorts and filters
  its own rows. `Listing` is a value, so the copy costs nothing until one of them changes it.
- **List the copy again and keep its copied rows on screen until the listing lands** — rejected:
  the rows are as new as the source's, and on a share the listing is the slow part. A change
  between the copy and its monitor's start is missed, as one between a first listing and its
  monitor's start is.
- **Scroll position in the model** — rejected: only the window knows it, and only once, when it
  makes the copy's view.
- **A grid layout type beside the split tree** — rejected: the tree holds an even grid, and focus,
  move, resize, equalize and the dividers all work on it unchanged.
- **Read the counts as leaves along an axis** — rejected: a tree with a 2 × 2 grid on one side
  would count as four columns.
- **Grid keys on the menu as "!" and "@"** — rejected: the keys differ by layout, and the menu
  would show ⌥⌘! for a key Dylan reads as ⌥⇧⌘1.
- **Override the key view loop in the table** — rejected: the filter field and the path bar have
  the keys at other times, and the window sees the event first in every case.

## Consequences

A split or grid on a fully listed folder reads nothing. A copy's monitor starts when its view does,
so a change in the folder in the milliseconds before that is missed until the next listing, as at
any pane's first listing.

Cmd-Opt-Shift-1 to 4 from the filter field do nothing, as Split does: only the window and tab
commands work outside the table. Whether a real Cmd-Opt-Shift-3 or 4 reaches the app with a
screenshot shortcut set to it is unchecked.

The UI bench's splits now copy the panes they split, so the grid it builds lists only what the
focus keys list.
