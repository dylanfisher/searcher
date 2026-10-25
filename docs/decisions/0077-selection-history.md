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
  replaced. That includes selections the app makes: the cursor moved after a trash, and what
  paste, New Folder, Duplicate, a rename or a drop select once listed. Changes the pane makes
  while keeping the selection (resolving it against a reload, patch or sort, settling it,
  leaving a folder) aren't steps. A new change ends the way forward. A selection with nothing
  selected and no cursor isn't kept, so the empty selection a trash leaves isn't a step.
- **Runs:** some changes join the step before them.
  - A row key's repeats, sent while it is held (`NSEvent.isARepeat`, carried to the command as
    `CommandContext.isKeyRepeat`), join the step of that key's press, however long they go on.
    Each separate press is a step of its own, as each move is in Sublime Text, so three taps
    of ↓ are three steps. A repeat joins only the same key's move (row count and whether it
    extends).
  - One mouse press in the table is one step, whatever it selects while the button is down and
    however long it pauses. Presses are counted in `ListingTableView.mouseDown`.
  - A type-to-select query is one step until a pause of 1 s, the pause that ends the query
    (`TypeSelect.resetInterval`).
  - Every other change is a step of its own.
- **Per folder:** each folder has its own steps, kept for the 20 folders changed most
  recently, 100 steps each. ⌘U never navigates: in a folder with no steps it does nothing, and
  back in a folder its steps are still there. A split's or a column's pane starts with none.
- **Restoring and skipping:** a step is resolved against the rows shown; a complete listing
  drops the names it no longer has, and the cursor goes with its entry. A step that would then
  select nothing listed and has no listed cursor, or would select just what is selected now,
  is skipped and dropped, and ⌘U goes on to the next. The items grey out when no step is left
  that would change the selection. Steps are kept by name without the listing Select All saw;
  a step taken before its click was named keeps its rows and that listing until it is
  restored.
- **Cost:** resolving a step is work per entry on the main thread, as a key's move is shown at
  once. The menus ask whether a step is left on each key equivalent, so the pane keeps the
  answer until its rows or selection change.

### The cursor after a trash

Move to Trash notes, on the press, the row after the cursor's run of selected rows in the
current sort, and the row before it. When the trash lands, by a folder change or a listing, and
the rows no longer list the cursor's entry and nothing is left selected, the cursor and
selection go to the row after, or the row before when the run ended the list. A run is the
cursor's block of adjacent selected rows; with several blocks, the row after the cursor's. Any
other change of the selection between the press and the landing cancels it, so a cursor the
user moved, or a selection emptied with a click on empty space, stays. When the trash ends, it
stays waiting only if the trash worked and trashed or deleted the cursor's entry: its folder
change usually arrives after the operation ends. A trash that failed, partly failed or was
cancelled at a question cancels it, so a row that leaves later for another reason moves
nothing. A row that leaves without a trash, such as one deleted in another app, still
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

- The first tests drove a table that holds a press's rows and posts the two notifications
  themselves, which is how two fixes passed and the press stayed broken; see the update below
  for the tests that press for real.
- The history holds names: a 50k-name selection kept in many steps costs that many name sets.
  The bounds (100 steps, 20 folders) cap it.

## Update 2026-10-24: selecting on mouse down, across panes

Dylan found twice that a press in another pane showed its row only on mouse up. The cause,
reproduced with a real `NSTableView.mouseDown` and its tracking loop:

- `NSTableView.mouseDown` doesn't select the pressed row until the mouse comes up (or a drag
  starts), in a focused pane as much as in another. It posts `selectionIsChanging` only then,
  so the first fix, which leaned on that notification, had nothing to react to.
- `NSWindow.sendEvent` makes the hit table first responder before it calls `mouseDown`. The
  second fix selected the row in `ListingTableView.mouseDown` but only `if window.firstResponder
  !== self`, so by then it always returned early. Its tests called the pre-step directly, on a
  table that wasn't first responder, and never ran the composition.

`ListingTableView.mouseDown` now selects the pressed row itself before calling `super`, whether
or not the table already has the keys (`selectOnPress`), taking the keys first (which focuses
the pane) so the pane has the row before the listing that taking focus starts can land. A press
on an already selected row, with Shift, Command or Control, or below the rows is left to AppKit,
so a drag still takes the whole selection, Shift- and Cmd-clicks extend and toggle, and a
context menu opens. A press in a focused pane selects at mouse down too; it did not before.
Column view's columns use the same table class.

The tests (`ListingTableView.realPress`, `Tests/InterfaceTests/RealPress.swift`) send a real
`mouseDown` with its mouse up queued first, read the table at each selection change, and tell
whether the button was still down by the mouse up still waiting in the queue. They fail without
the fix, in list view and in column view. Two harness facts, found the hard way: once `NSApp.nextEvent` has pulled events, HIToolbox
queues blocks on the main run loop, at any time after, that each stop it, to wake a `nextEvent`
that is no longer waiting. One that runs in the outermost main run loop, the loop that keeps the
Swift Testing runner alive, ends the process with exit status 0 and no summary. Draining the
queue and running the loop more did not help: the blocks arrive after the press, and a stop
from a block is not told apart from the Swift runtime's own except by its caller. So the
`BeepInterpose` dylib also replaces `CFRunLoopStop`; once a test calls
`dropStrayMainRunLoopStops()` (`realPress` does), it drops every stop of the main run loop that
the Swift runtime did not make, and counts them (`RealPressTests`). And a second `window.sendEvent`
of a press in one process is dropped, so the helper makes the table first responder itself, as
`NSWindow` does, and calls `mouseDown`. The helper waits on conditions only: the reposted mouse up
is in the queue when the press returns. `clickedRow` is -1 while the press selects, so the pane's
cursor comes from the selected row; `aRealPressAfterAnotherPutsTheCursorOnItsOwnRow` presses
rows in turn to check it. The test windows are not key
(0091), so the selection's drawn colour, emphasized or not, is not tested; with the window not
key, AppKit selects nothing at mouse down in either case, which is the behaviour that the
reproduction shows. Whether it looks right in a key window: needs Dylan.
