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
  (Cmd-↑) is ←; Back and Forward, and their enabled state, are the owner's. A column's pane
  never navigates or goes to a folder itself, and traps if asked.
- **The trail follows selections.** Each change a column's pane reports goes to the trail,
  which keeps the column to its right on the folder selected in it: one selected folder, found
  by the cursor's row, gets a column; anything else, a file, several rows or none, truncates the
  columns to its right. While the cursor's entry hasn't arrived in a partial listing, the
  columns stay. → and ← move the focus without listing anything again; → into a column with
  nothing selected selects its first row once the column has rows. Past the first column, ←
  adds the parent's column with the folder selected. (Superseded 2026-10-25: the first column is
  the root of the folder's volume, and ← there does nothing, as in Finder; see
  [0103](0103-column-trail-from-the-root.md).)
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
  mattering, and it ignores folder changes and settings changes. Switching back to the list moves the
  pane to the focused column's folder, in that column's sort, selecting the entry under its
  cursor, and lists it. Neither switch is a step in the history.
- **History.** Moving between columns isn't a step. Back, Forward, Go to folder, a path bar click
  and a link to a folder record the focused column's folder and cursor, as a list pane records
  its own, and start the trail again with one column at the destination, the remembered entry
  selected, in the sort of the focused column it replaces. Every old column closes. (Amended
  2026-10-25: the new trail runs from the root of the destination's volume down to it; a path
  bar click on a folder that has a column moves the focus there instead, keeping every column,
  and is no step; see [0103](0103-column-trail-from-the-root.md).)
- **Filter.** The filter belongs to the column it was typed in and narrows that column only. It
  stays with the column until the column closes; a navigation closes every column, so it clears
  the filter as it does in a list.
- **Sort.** A sort key sorts the focused column. A new column takes the sort of the column it
  opens from. Hidden files and folders first are app-wide `Settings`, which every column observes.
- **Keys.** → and ← are commands in `ColumnCommands`; in list mode they do nothing. Cmd-1 and
  Cmd-3 are `ViewCommands.asList` and `asColumns`. Neither chord is used elsewhere in the key
  table: the sort keys are Ctrl-Opt-Cmd-1 and 2, and split resizing is Ctrl-Cmd-arrows.

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
- **Count column moves as history steps** — rejected: Back would step through every column the
  arrows passed, and the list keeps no such steps for ↑ and ↓.
- **Hand the owner's listing to the first column on the switch** — not now: the column lists the
  folder again. M2.3's cache makes that read cheap on a share.

## Consequences

Switching views lists the folder again, and so does Go to folder in column mode once it has
found the folder. → into a column whose rows haven't arrived selects nothing; the first row
isn't selected when they arrive. ← keeps the columns to the right, so → goes back into the same
folder. A closed column's settings observer stays in `Settings` until the next settings change
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
