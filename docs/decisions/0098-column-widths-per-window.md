# 0098. Column widths per window: kept by folder in each pane, saved with the session

- **Date:** 2026-10-24
- **Status:** accepted

## Context

[0096](0096-column-widths.md) made columns resizable, but kept each width in the column view
only: a relaunch, a workspace reload and a switch to the list and back showed every column at
`Settings.columnWidth`. Dylan asked for a window's widths to come back as they were, as Finder
keeps a window's column widths when it reopens it, and for the persistence to have no edge
cases. `TabState` keeps a column-mode pane's focused folder only, so a restore shows one column
([0041](0041-column-model.md), [0080](0080-restore-at-launch.md)). A saved workspace reopens in
its saved state, and the edited dot shows any difference from it; a window that only moved is
moved back without rebuilding its panes ([0088](0088-workspace-snapshots.md)). B1 (500 ms) holds
for a restored session, and restore doesn't wait on any folder ([0081](0081-restored-network-panes.md)).

Finder's own model couldn't be read. Its preferences hold one `ColumnWidth`
(`StandardViewOptions` ▸ `ColumnViewOptions`), and its per-window state is in its saved
application state, which isn't readable; finding out by hand would mean opening Finder windows on
the main display, which the build rules don't allow. It is one of the checks by hand below.

## Decision

- **What is stored: a width per folder, and the preview's.** `ColumnWidths` holds the folders
  whose column a grip resized, each with its width, and the preview's width once its grip set
  one. A column shows its folder's width, or `Settings.columnWidth` with none; the preview the
  same. Folders, not positions, because ← past the first column inserts a column on the left,
  which would move every positional width to the next folder over (0096). A folder's width
  follows it wherever it shows in the trail: reopened after its column closed, added on the
  left by ←, or the one column a restore shows.
- **Which state: the pane's.** `Pane.columnWidths` belongs to the pane, in list mode too, so the
  switch to the list and back keeps them, and so does a tab switch, which keeps the pane. A
  split's copy has them; a new tab or window starts with none, as a new Finder window does.
  `TabState.PaneState` stores them, so the session, each window file and each snapshot have
  them. A pane moved to another window takes them along.
- **The cap.** At most `ColumnWidths.folderLimit`, 64, folders per pane. Setting one more drops
  the folder set longest ago; setting a folder to the width it has moves nothing. Widths are
  never checked against the disk: a folder gone, unreadable, or on a share that isn't mounted
  shows its missing, denied or offline state at its stored width, and its entry ages out under
  the cap. Restore reads no more than the file it already decodes, and nothing waits.
- **When the pane takes a width.** A drag lays the columns out at the drag's width on every
  event and hands the pane the width once, on release (`Pane.setColumnWidth`,
  `setPreviewWidth`); a fit hands it when it lands; each VoiceOver step hands it its step. Each
  is one pane change, which reaches the save path as any change does: `WorkspaceWindows` saves
  `saveDelay` after the changes stop, and the store writes a second later
  ([0080](0080-restore-at-launch.md)). A drag starts one save, not one per event. A plain drag
  that ends at the width it started from, and a click on a grip, hand the pane nothing, so they
  are no edit.
- **A double-click back from a fit** (amended 2026-10-24, [0096](0096-column-widths.md)) takes
  the folder's width out (`Pane.clearColumnWidth`): one pane change, an edit like any other,
  after which the column is unresized again and follows the live default, with nothing stored
  for it. Clearing a folder with no width hands the pane nothing. A relaunch shows the column
  at `Settings.columnWidth`, as it shows any unresized one.
- **Option-drag and the app-wide default** (decided 2026-10-24 in review). An Option-drag or
  Option-double-click sets every column and the preview to one width and makes it
  `Settings.columnWidth`, as before; an Option-double-click back from the fit does the same
  with `Settings.defaultColumnWidth`. The pane's folder widths go with it, shown or not, so every
  column of that pane is at the new width and a folder reopened later is too. Every other
  column with no width set, in every pane and window, follows the live default: it changes
  width on screen at once, and nothing is stored for it. Only grip-set widths are ever in
  `columnWidths`. This matches Finder's single `ColumnWidth`, and an Option-drag in one window
  never sets the edited dot of another saved window, whose state is unchanged.
- **New columns in a restored window**, and its columns whose folder has no stored width, get
  `Settings.columnWidth` as it is then, as every unresized column does.
- **Snapshots: widths are saved state, handled as the frame is.** Save Workspace keeps the
  widths; reopening a closed saved workspace shows them. A resize after a save is an edit: the
  edited dot shows once the save path reads the state, as for any other change. Going to an
  open saved workspace whose window differs from its snapshot only in its frame and its widths
  moves the window and gives each pane the snapshot's widths in place
  (`Workspace.showColumnWidths`), keeping the tabs, panes, scroll positions and histories, as a
  frame-only difference does; any other difference reloads the snapshot as before. The three
  orders: resize then save then reopen shows the resized widths with no dot; save then resize
  shows the dot, and going back shows the saved widths and clears it; resize without saving
  and relaunch shows the resized widths with the dot, and going back clears both. Two width
  sets that hold the same widths in another order are equal, so the order kept for the cap
  never sets the dot.
- **Stored shape.** A pane stores `columnWidths` only when it has a width:
  `{"folders": [{"path", "width"}, …], "preview"}`, folders set longest ago first, `preview`
  left out when unset. A pane with none stores no key, which is what every file written before
  this change holds, so those files load as they are, with no widths, and nothing is migrated.
  Widths of another shape — present but empty, a folder twice, more than 64 folders, a width
  outside `Settings.columnWidths` or not a number — make the workspace file undecodable, which
  the store deletes and reports, as for any other mismatch ([0078](0078-workspace-store.md)).
  (Superseded 2026-10-25, CV.14: widths are whole points too, which widths dragged with a
  trackpad before then aren't, so this rule would have deleted Dylan's saved workspaces over a
  width. A pane's widths that are present but empty, hold a folder twice, more than 64 folders,
  or a width `Settings.isColumnWidth` rejects are dropped alone: the pane loads with no widths
  and its columns follow the live default, and the rest of the file loads. The store writes the
  file back without them and reports it once (`StoreProblem` kind `widthsDropped`). That is
  still the pre-release rule, data of another shape is discarded with no migration and no
  rounding, at the widths' granularity. A width that isn't a number, or any other key or value
  of another shape, still discards the file. A saved workspace and its window that stored the
  same bad widths both load without them, so they stay alike and the window shows no edited
  dot; a window whose widths were dropped while its snapshot's were good differs from it, and
  shows the dot, which is right: going back to the snapshot gives the saved widths.)
- **No undo.** A resize isn't undoable, as in Finder and as 0096 has it.

## Alternatives considered

- **Widths by column position** (`NSBrowser`'s autosave) — rejected for 0096's reason: ← past
  the first column shifts them.
- **One width per pane, plus per-column overrides** — rejected: a per-pane base would be a third
  value beside `Settings.columnWidth` and the folder widths, and it would disagree with 0096's
  rule that an Option-drag sets the width new columns get in every window.
- **Pin the old default into each other pane's state when the default changes**, so no column
  on screen changes width — rejected in review: it would set the edited dot of every other saved
  window in column view after one Option-drag, with nothing the user did there, and store
  widths nobody set. Keeping such a pin in memory only, out of the state, was rejected too: a
  relaunch or a reload would then show different widths from the ones on screen.
- **Store every shown column's width, resized or not** — rejected: every column opened would
  change the stored state and set the edited dot with nothing visibly changed, and a folder
  revisited after an Option-drag elsewhere would keep the old default.
- **Widths in the window (`WorkspaceState`) or the tab** — rejected: two panes of one tab can
  show the same folder at different widths, and a pane moved to another window would leave its
  widths behind.
- **Store the trail** so a restore shows every column — not done here: it is a second change to
  what `TabState` keeps (0041) and to what restore lists; the folder widths are ready for it.
- **A width-only difference from the snapshot reloads the workspace** — rejected: it would close
  and rebuild every tab, list every folder again and drop scroll positions and histories, for a
  difference that a frame-only reload already avoids.
- **Discard only the bad widths, keeping the workspace** — rejected at first: stored data has
  one shape, and every other mismatch in a workspace file discards the file. (Taken 2026-10-25,
  CV.14, see Stored shape: a workspace is worth more than its widths, and widths dropped alone
  cost nothing the columns can't show again.)

## Consequences

A restored column-mode pane shows its one column, and any column ← or a selection opens, at its
folder's stored width. An Option-drag in one window moves the unresized columns of every other
window, as one app-wide width does, and changes no stored state but its own pane's. A pane keeps
the widths of at most 64 folders.

Checks by hand, with Finder: whether Finder keeps a resized column's width for its folder or for
its position (resize the second column, click another folder in the first, and see which width
the new second column gets); whether a relaunch shows a window's resized columns; and whether an
Option-drag in one window resizes another window's columns. A difference from this record is a
change to `ColumnWidths` or to `Pane.columnWidth(of:)`.
