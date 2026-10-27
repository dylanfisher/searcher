# 0112. Soft undo remembers where the keys were: one history per tab

- **Date:** 2026-10-26
- **Status:** accepted
- **Amends:** [0077](0077-selection-history.md): "Per folder" and "⌘U never navigates".

## Context

Dylan, 2026-10-26: "soft undo (cmd+u) should also remember pane traversal and movement across
panes. so if you are in column 2 file 1, move left to column 1 move down to file 2, then press
cmd+u twice you will get back to column 2 file 1. if you move pane and then press cmd+u you'd
move back to the pane you were at." 0077 kept each folder's selections apart in the pane showing
it, and a column's pane is gone when its trail closes the column, so moves between columns and
panes could not be steps.

This record landed in two steps. SU.1a moved the steps from each pane to one history per tab,
with a step as a position. SU.1b added the moves of the keys between columns and split panes as
steps of their own, and restoring into a column the trail has closed.

## Decision

- **A step is a position:** the tab's pane (its `PaneID`), the folder, which in column view names
  the column, and the selection there, kept by name (`SelectionHistory.Position`). Never a `Pane`
  or a column index: a column's pane goes when its trail closes the column. Each change of a
  selection keeps the position before it, as 0077's steps did, and each move of the keys to
  another split pane or column keeps the position the keys left, even with nothing selected
  there: the focus is what changed. Undo restores the nearest step and keeps where the keys were,
  with the selection there, as the way forward, so Redo puts the keys back.
- **Moves of the keys that are steps:** ← and → in column view, a press in another column or
  pane, Go to Item's choice in the selected folder's column, a path bar click on a column, Open
  on a folder in a column, the split focus keys, Focus Other Pane, and a split, whose new pane
  takes the keys (`ColumnTrail.focus(_:recordsStep:recordingAs:)`, beside the Back entry the same
  move makes, and `Tab.focus`, `Tab.split`). Not steps: the sidebar, which is not a position, so
  moving the keys into or out of it is none; Back and Forward; Undo and Redo Selection
  themselves; a drag's spring-loaded folders; the root check and home correction of a trail; a
  trail closing the column the keys were in; and the refocus after Open in Other Pane's split.
  → 's selection of the first row in the column it moves into is part of its step.
- **One history per tab** (`Tab.selectionHistory`): steps of every pane and column of the tab,
  newest last. Not per window, since ⌘U in another tab would act on keys the window doesn't show,
  and not per pane, since a move between panes has to be undone too. A pane reports through the
  tab that holds it (`Pane.tab`); a column through its trail's owner. Undo and Redo Selection run
  on the tab (`SelectionCommands` through `CommandContext.pane.tab`); a pane in no tab, as a bench
  makes one, has them off.
- **Restoring:** the step's pane takes the focus, and in column view the step's column the keys,
  adding nothing to Back: Back is the folders a pane left, and ⌘U puts the keys back in a trail
  the pane never left (`Pane.restore` sets the same flag Back uses). From the sidebar, ⌘U and ⇧⌘U
  give the keys to that pane, as the Focus Pane commands do
  ([0089](0089-sidebar-key-routing.md)). A step of a column the trail has closed since opens it
  again: the trail starts again at its folder, keeping the columns of the folders above it
  ([0103](0103-column-trail-from-the-root.md)), as a navigation does, but with no Back entry and
  no barrier (`Pane.reopenColumn`). The selection resolves against the rows, skipping and
  dropping as 0077, except that a step that moves the keys is never skipped. A column that hasn't
  listed yet, just reopened or opened again by the step before, can't tell what its rows hold:
  its step is restored by name, the names waiting for the rows as any selection made before them
  does, and counts as a step left. Two quick presses of ⌘U on Dylan's case so never lose the
  column's step.
- **Navigation is Back's job, and a barrier for ⌘U.** A change of the folder a pane shows other
  than a move inside its column trail (entering a folder in the list, Enclosing Folder, a path bar
  click on a folder no column shows, Go to Folder, the sidebar, Back and Forward to a folder the
  trail doesn't show), and a switch of view mode, drop that pane's steps, back and forward,
  including its columns'. The hooks are `Pane.leave(for:selection:isNavigation:)`, which every
  navigation and trail restart goes through, and `Pane.setViewMode`. Other panes' steps stay.
  Moves inside a trail (selecting a folder, ←, →, Back and Forward to a shown column, ⌘U's own
  restart) are no barrier. A drag's spring-loaded folders are none either: the drag's end comes
  back ([0099](0099-get-info-and-spring-loading.md)). Listing the folder the pane is in again
  keeps the steps. (Amended 2026-10-26: a folder chosen in Open Quickly is such a navigation,
  and the first row it selects once listed ([0087](0087-palette-window.md)) is part of it, as →
  's first row is part of its step: it records no step. ⌘U right after has nothing to step to,
  and after a move returns to that first row.) This replaces 0077's per-folder steps: a step could otherwise name a folder
  the pane no longer shows, which ⌘U would have to navigate to or leave unreachable.
- **Dropped:** a pane's steps when it closes, a grid takes it out, or it moves to another window
  (`Tab.removeFocusedPane`), where it starts with none. A split's new pane starts with none.
- **Limit:** 100 steps per pane, its oldest going first. 0077's limit of 20 folders goes: the
  barrier bounds the folders a pane's steps can name.
- **Runs:** as 0077 (a held row key's repeats, a type-to-select query until its pause), and a
  held focus key's repeats join its press's step whatever columns or panes they cross; each
  press is a step of its own. One mouse press is one step wherever it moves the keys: a press in
  another column or pane records the position the keys left, and the rows it selects there join
  it. Press numbers count across every table (`ListingTableView.pressCount`), and the window
  gives a table the keys before it sends the press to the table, so whichever sees a press first
  numbers it. Row-key and query runs join only in the same pane and folder.
- **Kept from 0077:** skipping steps that would change nothing and dropping them, greying the
  items out with nothing to step to, keeping steps by name, and no persistence. Whether a step is
  left is cached per tab until anything a pane reports changes, or the layout or the history
  does.

## Consequences

- Coming back to a folder no longer finds its old steps.
- ⌘U can move the focus to another pane, or the keys to another column, and opens a column the
  trail closed since.
- A press, or Go to Item's choice, that moves the keys and selects is one step, so the selection
  it replaced where the keys went isn't kept: ⌘U returns the keys to where they were and leaves
  the new selection there. Needs Dylan; the lossless alternative is two steps per click.
- Redo puts the keys back where Undo found them, with the selection there. A column whose
  selection changed while the keys were elsewhere, as one opened again empty, keeps the selection
  Undo gave it after the Redo.
