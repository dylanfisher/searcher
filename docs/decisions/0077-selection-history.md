# 0077. Selection undo, the cursor after a trash, and selecting on mouse down

- **Date:** 2026-10-23
- **Status:** accepted

## Context

Dylan asked on 2026-10-23 for three selection changes: Sublime Text's soft undo and redo for
the selection alone, the cursor moving to the next row after the focused row is trashed, and a
press in an unfocused pane selecting the pressed row at mouse down rather than mouse up. File
Undo (⌘Z) stays file changes only ([0072](0072-undo.md)).

## Decision

### Selection undo

- **Keys and items:** Undo Selection ⌘U and Redo Selection ⇧⌘U, Sublime Text's soft undo
  keys. Neither chord was bound. Their items sit under Edit's Undo and Redo and grey out with
  nothing to step to. They are `SelectionCommands`, held per pane in `SelectionHistory`, apart
  from `UndoHistory`.
- **What a step is:** each change of the pane's selection (`Pane.set`) keeps the selection it
  replaced. Changes the pane makes itself (resolving, settling, leaving a folder) aren't steps.
  A new change ends the way forward. A selection with nothing selected and no cursor isn't kept,
  so the empty selection a trash leaves isn't a step.
- **Runs:** changes from one source, each within 1 s of the last (`TypeSelect.resetInterval`),
  are one step. The sources are a row key's move (by its row count and whether it extends, so
  ↓ held is one run and ↓ then ↑ two), a type-to-select query (the same 1 s ends a query), and
  one mouse press in the table (counted in `ListingTableView.mouseDown`, so a drag across rows
  is one step). Every other change is a step of its own. AppKit's key-repeat flag isn't used:
  the command layer doesn't see the event, and taps of ↓ less than a second apart count as one
  run too.
- **Per folder:** each folder has its own steps, kept for the 20 folders changed most
  recently, 100 steps each. ⌘U never navigates: in a folder with no steps it does nothing, and
  back in a folder its steps are still there. A split's or a column's pane starts with none.
- **Restoring:** a step is shown provisionally and settled off the main thread, as a selection
  changed under a landing load is, so a large one costs the main thread one screen of rows. A
  complete listing drops the names it no longer has; the cursor is dropped with its entry.
  Steps are kept by name without the listing Select All saw; a step taken before its click was
  named keeps its rows and that listing until it is restored.

### The cursor after a trash

Move to Trash notes, on the press, the row after the cursor's run of selected rows in the
current sort, and the row before it. When the trash lands, by a folder change or a listing, and
the rows no longer list the cursor's entry and nothing is left selected, the cursor and
selection go to the row after, or the row before when the run ended the list. A run is the
cursor's block of adjacent selected rows; with several blocks, the row after the cursor's. Any
other change of the selection between the press and the landing cancels it, so a cursor the
user moved stays. A row that leaves without a trash, such as one deleted in another app, still
leaves no cursor. A trash that falls back to deleting immediately runs through the same press.

Finder wasn't checked on this machine (the build agent doesn't drive other apps). As recalled,
Finder's list view also selects the next item after Move to Trash; Dylan to confirm, and to
check what it does at the end of the list and after a multi-row trash.

### Selecting on mouse down

`NSTableView` selects the pressed row in its own rows at mouse down, posts
`selectionIsChanging`, and posts `selectionDidChange` only at mouse up. The list reported only
the second. A press in an unfocused pane focuses it, which lists its folder again
(`Pane.didGainFocus`); when that listing landed while the button was down, showing it put the
pane's old selection back in the table until mouse up. The list now reports
`selectionIsChanging` too, when the table's rows differ from the pane's. A press inside a
multi-row selection leaves the table's rows alone until mouse up, as AppKit and Finder do, so a
drag still takes every selected row. The pane ignores a report of the rows, cursor and anchor
it already has, so mouse up after mouse down changes nothing and is no second step.

## Consequences

- A real press can't be sent in a test, since the table tracks it in a nested run loop; the
  tests drive a table that holds a press's rows and posts the two notifications.
- The history holds names: a 50k-name selection kept in many steps costs that many name sets.
  The bounds (100 steps, 20 folders) cap it.
