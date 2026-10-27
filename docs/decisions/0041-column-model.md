# 0041. Column model: each column is a Pane, and keys act on the focused column's

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M2.6 gives a pane a view mode, list or column (Cmd-1, Cmd-3). In column mode the pane holds a
trail of columns, each with its own listing, selection, load and watch (`tmp/behavior.md`: →
into the selected folder, ← to the parent column, Cmd-↑ or ← past the first column adds the
parent on the left, no preview column; superseded 2026-10-24: one selected file shows a
preview, see [0090](0090-preview-column.md)). The plan asks columns to use the pane's load path, so
that M2.3's cached and offline states reach them without a second copy. `Pane` holds that path:
the load through `ListingService`, the off-main sort and filter ([0025](0025-sort-off-main.md),
[0031](0031-view-settings.md), [0037](0037-type-to-filter.md)), patches, and selection settling
([0029](0029-row-movement.md)). `PaneViewController` starts the folder monitor and hands it to
`Pane.monitor` ([0019](0019-pane-model.md)). Commands get one pane through `CommandContext`.

## Decision

- **A column is a `Pane`.** `Column` holds a `Pane`, made by the trail with the owner's service,
  settings and system actions, so a column loads, sorts, filters, patches and settles exactly as
  a list pane does, and M2.7 can show it with `ListingViewController`, which takes a `Pane`.
  The column's pane knows its trail (`containingTrail`), and the trail knows its owner, the
  pane in column mode.
- **Commands act on `Pane.commandPane`.** It is the pane itself in list mode and the focused
  column's pane in column mode; the view builds `CommandContext` with it. So row keys,
  type-to-select, the sort keys, Quick Look, Copy Path and the filter act on the focused column
  with no change to their commands. A column's pane sends the commands that move between
  folders to its trail: Open on a folder moves into its column, as → does; Go to parent
  (Cmd-↑) is ← (amended 2026-10-25: except in a first column at the home folder, where it goes
  up; see [0103](0103-column-trail-from-the-root.md)); Back and Forward, and their enabled
  state, are the owner's. A column's pane
  never navigates or goes to a folder itself, and traps if asked.
- **The trail follows selections.** Each change a column's pane reports goes to the trail,
  which keeps the column to its right on the folder selected in it: one selected folder, found
  by the cursor's row, gets a column; anything else, a file, several rows or none, truncates the
  columns to its right. While the cursor's entry hasn't arrived in a partial listing, the
  columns stay. → and ← move the focus without listing anything again; → into a column with
  nothing selected selects its first row once the column has rows. Past the first column, ←
  adds the parent's column with the folder selected. (Superseded 2026-10-25: the first column is
  the root of the folder's volume, and ← there does nothing, as in Finder; see
  [0103](0103-column-trail-from-the-root.md).) (Amended 2026-10-25, Dylan: "if you click a left
  folder that is currently open in column mode it should close the right columns and show only
  the items of that folder you clicked on": a plain press on the row selected alone in a column,
  at mouse down, where [0077](0077-selection-history.md)'s press selects a row, makes the column
  that selection opens the last one, with nothing selected in it, as in Finder
  (`ListingTableView.pressedSelectedRow`, `ColumnTrail.showNextColumnAlone`). The pressed column
  keeps its selection and takes the keys. A press on a folder not selected already opened its
  column fresh. A press that starts a drag of the folder closes the columns too; they showed the
  folder's own contents, which can't take it, and spring-loading
  ([0099](0099-get-info-and-spring-loading.md)) opens the folders the drag hovers over as before.
  A selection waiting for the keys to pause ([0094](0094-column-open-delay.md)) opens its column
  at the press. ← still keeps the columns to the right. (Amended 2026-10-27: Escape then closes
  them as the press does; see [0119](0119-escape-closes-columns.md).))
- **Loads.** Each column's pane lists its folder. The focused column's load asks
  `ListingService` for `.focused` priority, so a parent column added by ← starts ahead of a
  child column queued before it, once both volumes are read; a load whose volume isn't known
  yet can't start, whatever its priority. A column that gains focus later keeps its place in
  the queue (superseded: its waiting load now moves to the front, see
  [0048](0048-pane-load-priority.md)). A slow update leaves a column as it leaves a list pane: still loading, with the
  trail unchanged.
- **Watches.** A column's watch is its pane's `monitor`. The view starts it, as
  `PaneViewController` starts the list pane's. A truncated column, and every column when the pane
  goes back to the list, closes its pane (`Pane.close`): the load is cancelled, the monitor
  stopped and dropped, and a monitor handed to it after that is stopped at once.
- **The owner in column mode.** Switching to columns stops the pane's own load and monitor and
  starts the trail with one column at its folder, with the entry under the cursor selected
  (superseded 2026-10-25: the trail has a column for every folder from the root of the folder's
  volume down, each with the next one selected, and the focused column at the folder; the
  focused column's load is asked first, see [0103](0103-column-trail-from-the-root.md)). The
  pane's `location` follows the focused column, for the path bar, the window title and History.
  Its own rows go: its state holds no listing, so a settings change sorts nothing in it and a
  view can't show or act on rows under a location that moved. Its filter and selection stop
  mattering, and it ignores folder changes and settings changes. Switching back to the list
  moves the pane to the focused column's folder, selecting the entry under its cursor, and lists
  it in the list's own sort (see Sort). Neither switch is a step in the history.
- **History.** Moving between columns isn't a step. Back, Forward, Go to folder, a path bar click
  and a link to a folder record the focused column's folder and cursor, as a list pane records
  its own, and start the trail again with one column at the destination, the remembered entry
  selected. Every old column closes. (Amended 2026-10-25: the new trail runs from the root of
  the destination's volume down to it; a path bar click on a folder that has a column moves the
  focus there instead, keeping every column, and is no step; see [0103](0103-column-trail-from-the-root.md).) (Amended 2026-10-25, Dylan:
  "forward/back should save the directory changing within columns. right now if i go back it
  jumps back to a cimpletely different directory, not just the last directory i was in within
  the columns.": the folder History keeps is the pane's, the focused column's, the one the path
  bar and the title show. Each move of the keys to another column is a step, recording the folder
  left and the entry under its cursor (`Pane.trailWillMoveFocus`), at the moments
  `FolderVisits` counts a visit ([0087](0087-palette-window.md)): → and ←, Open on a folder,
  a click in another column, a path bar click, and a column closing under the focus, as a
  removed folder's does. ↑ and ↓ move the selection inside the focused column, so a held key
  through folders makes no step, however many columns open after it pauses
  ([0094](0094-column-open-delay.md)). Back and Forward, a drag's spring-loaded folders and the
  way back from them make none. Finder's title follows the selected folder, so in Finder a
  selected folder may be the step and ← none; here the title follows the focused column, so the
  steps follow it too, and ← is one. That is a hand check against Finder. Back or Forward to a
  folder the trail shows doesn't build the trail again (`ColumnTrail.show`): its column takes
  the keys with the remembered entry selected, the column that entry opens is the last one, with
  nothing selected in it, and nothing lists again but a folder whose column had closed. Any
  other folder starts the trail again as above, and one gone since shows the failed state
  ([0033](0033-history-and-go-to-folder.md)). `History` keeps the same two stacks of a folder
  and a name, so `TabState` stores and restores it as before
  ([0042](0042-workspace-model.md)).) (Amended 2026-10-25, Dylan: "in general i want to avoid
  flash": starting the trail again keeps the old trail's columns from the root down as far as
  both trails run through the same folders, with their rows, monitors and views; only the
  others close. See [0103](0103-column-trail-from-the-root.md).)
- **Filter.** The filter belongs to the column it was typed in and narrows that column only. It
  stays with the column until the column closes; a navigation closes every column, so it clears
  the filter as it does in a list. (Amended 2026-10-25: a navigation keeps the columns both
  trails show ([0103](0103-column-trail-from-the-root.md)) and clears their filters.)
- **Sort.** A sort key sorts the focused column. Hidden files and folders first are app-wide
  `Settings`, which every column observes. (Amended 2026-10-26, Dylan: "column view should always
  default to order name ascending unless you change the order for that particular column. column
  and other views should only ever be sortable by the information visible (in column view that's
  only name), in list view that's any of the headers present": every column opens sorted by Name
  ascending (`Pane.columnSort`): a column opened from another, the columns a navigation or a
  restore builds, those of a switch from the list and a split's. Only a sort key in a column
  changes its sort, for as long as it stays open; a column a navigation keeps
  ([0103](0103-column-trail-from-the-root.md)) keeps its sort. A column sorts by Name only
  ([0031](0031-view-settings.md)). The pane's own sort is the list's: column mode leaves it as it
  was, the switch back lists in it, `Tab.state` saves it and a split, New Tab and New Window copy
  it ([0042](0042-workspace-model.md), [0078](0078-workspace-store.md)). Column sorts aren't
  saved.)
- **Keys.** → and ← are commands in `ColumnCommands`; in list mode they do nothing. Cmd-1 and
  Cmd-3 are `ViewCommands.asList` and `asColumns`. Neither chord is used elsewhere in the key
  table: the sort keys are Ctrl-Opt-Cmd-1 and 2, and split resizing is Ctrl-Cmd-arrows.
  (Amended 2026-10-26: the sort keys are Ctrl-Opt-1 to 4 ([0031](0031-view-settings.md)).)

## Alternatives considered

- **Extract a per-folder model from `Pane` for list panes and columns to share** — rejected for
  this step: `Pane` already is that model, and moving its load, sort, patch and settle code into a
  new type would rewrite most of the file while M2.1 and M2.3 change it. A column's pane carries
  a history and a view mode it never uses, which costs a few empty fields.
- **Keep `CommandContext.pane` as the owner and route row commands inside it** — rejected: type-
  to-select and Copy Path read the pane's rows and selection directly, so every read would need
  forwarding too.
- **Re-list a column each time it gains the focus, as a pane does** — rejected: each → and ←
  would read a folder again, which on a share is slow; each column's monitor keeps it current.
  Focusing the pane itself still re-lists the focused column.
- **Requeue a waiting load at focused priority when its column gains the focus** — rejected:
  `ListingService` can't tell a waiting load from a running one, and restarting a running load
  throws away what it read.
- **Count column moves as history steps** — rejected at first: Back would step through every
  column the arrows passed, and the list keeps no such steps for ↑ and ↓. Reversed by Dylan,
  2026-10-25: "forward/back should save the directory changing within columns. right now if i go
  back it jumps back to a cimpletely different directory, not just the last directory i was in
  within the columns." Moves of the focus are steps now; ↑ and ↓ still make none (see History).
- **Hand the owner's listing to the first column on the switch** — not now: the column lists the
  folder again. M2.3's cache makes that read cheap on a share.

## Consequences

Switching views lists the folder again, and so does Go to folder in column mode once it has
found the folder. → into a column whose rows haven't arrived selects nothing; the first row
isn't selected when they arrive. ← keeps the columns to the right, so → goes back into the same
folder; Escape closes them ([0119](0119-escape-closes-columns.md)). A closed column's settings observer stays in `Settings` until the next settings change
after the column is freed, which drops it; pruning on `close()` would need a removal method in
`Settings`, and a closed pane ignores settings changes meanwhile.

For M2.7, which builds the view on this model:

- Show the columns, not the owner's list, in column mode; the owner holds no rows then.
- Read the view mode from the owner: a column's pane reports `.list`.
- Build `CommandContext` with `commandPane`, and have the filter bar call `setFilter` on it.
- The path bar and `GoToFolderSheet` keep the owner, which navigates and goes to folders.
- Set no `onChange` on a column's pane: the trail owns it and reports every column change
  through the owner's `onChange`.
- Set each column's `visibleRowCount`, so Page Up and Page Down move a column's page.
- Start a monitor for each column's pane, none for the owner in column mode, and the list's
  again after switching back.
- `ColumnTrail.owner` is unowned: keep no trail alive past its pane.
- Cmd-3 cancels a pending link open or Go to folder without calling its `finish`, as any
  navigation does.
- ← and → are bound commands that do nothing in list mode, so they no longer reach
  `NSTableView` there.
