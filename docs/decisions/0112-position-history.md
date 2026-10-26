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

This record lands in two steps. SU.1a, built here, moves the steps from each pane to one history
per tab, with a step as a position. SU.1b adds the moves of the keys between columns and split
panes as steps of their own, and restores into a column the trail has closed.

## Decision

- **A step is a position:** the tab's pane (its `PaneID`), the folder, which in column view names
  the column, and the selection there, kept by name (`SelectionHistory.Position`). Never a `Pane`
  or a column index: a column's pane goes when its trail closes the column. Each change of a
  selection keeps the position before it, as 0077's steps did. Undo restores the nearest step and
  keeps what it replaced, the selection in the same pane and folder, as the way forward.
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
  ([0089](0089-sidebar-key-routing.md)). The selection resolves against the rows, skipping and
  dropping as 0077. A step of a column the trail no longer shows is skipped and dropped until
  SU.1b opens it again.
- **Navigation is Back's job, and a barrier for ⌘U.** A change of the folder a pane shows other
  than a move inside its column trail (entering a folder in the list, Enclosing Folder, a path bar
  click, Go to Folder, the sidebar, Back and Forward to a folder the trail doesn't show), and a
  switch of view mode, drop that pane's steps, back and forward, including its columns'. The hooks
  are `Pane.leave(for:selection:)`, which every navigation and trail restart goes through, and
  `Pane.setViewMode`. Other panes' steps stay. Moves inside a trail (selecting a folder, ←, →,
  Back and Forward to a shown column) are no barrier. A drag's spring-loaded folders are none
  either: the drag's end comes back ([0099](0099-get-info-and-spring-loading.md)). Listing the
  folder the pane is in again keeps the steps. This replaces 0077's per-folder steps: a step
  could otherwise name a folder the pane no longer shows, which ⌘U would have to navigate to or
  leave unreachable.
- **Dropped:** a pane's steps when it closes, a grid takes it out, or it moves to another window
  (`Tab.removeFocusedPane`), where it starts with none. A split's pane starts with none.
- **Limit:** 100 steps per pane, its oldest going first. 0077's limit of 20 folders goes: the
  barrier bounds the folders a pane's steps can name.
- **Kept from 0077:** runs (a held key's repeats, one mouse press, a type-to-select query until
  its pause), skipping steps that would change nothing and dropping them, greying the items out
  with nothing to step to, keeping steps by name, and no persistence. A run joins only changes in
  the same pane and folder. Whether a step is left is cached per tab until anything a pane reports
  changes, or the layout or the history does.

## Consequences

- Coming back to a folder no longer finds its old steps.
- ⌘U can move the focus to another pane, or the keys to another column, where the selection was
  changed.
- Needs Dylan for SU.1b: a press that moves the focus and selects is planned as one step, so the
  destination's replaced selection isn't kept; the lossless alternative is two steps per click.
