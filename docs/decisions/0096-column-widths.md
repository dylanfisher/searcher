# 0096. Column widths: a grip per column, an app-wide default for new ones

- **Date:** 2026-10-24
- **Status:** accepted

## Context

Column view's columns were a fixed 240 points ([0046](0046-column-view.md)), and the preview had
the same width ([0090](0090-preview-column.md)). Finder lets each column be resized by the "||"
grip at the bottom of its right edge. Finder's own preferences (`defaults read com.apple.finder`,
`StandardViewOptions` ▸ `ColumnViewOptions`) hold one `ColumnWidth`, 245, for the columns new
windows get. `NSBrowser`, whose behavior Finder's column view follows, documents the gestures: a
drag resizes one column, Option switches to resizing every column together, and a double-click
right-sizes, one column plain and every column at one width with Option
(`prefersAllColumnUserResizing`, `browser:sizeToFitWidthOfColumn:` in `NSBrowser.h`). B6 (16 ms
key to frame) and B10 (no main-thread stall over 50 ms) hold while the user resizes, and the
session and workspace files ([0080](0080-restore-at-launch.md), [0081](0081-restored-network-panes.md),
[0088](0088-workspace-snapshots.md)) must not drift from what the window shows.

## Decision

- **A grip per column and one for the preview.** `ColumnGripView` is an 11 × 16 point view
  centered on the column's separator line at the bottom of the column, over the horizontal
  scroller's area. It covers the separator there with the column background and draws two 1-point
  lines, 9 points tall and 3 points apart, in `tertiaryLabelColor`, so it follows light and dark
  mode. The pointer over it is `resizeLeftRight`. The preview has its own grip at its right edge;
  it is hidden with the preview. The grips stay above the columns, which each overlaps by 5 points.
- **Drag.** A drag resizes its column alone; the columns right of it move. An Option-drag resizes
  every column and the preview to the dragged column's new width, and on release sets
  `Settings.columnWidth`, the width new columns get. A plain drag leaves that default alone.
  Whether Option is held is read at the press. An Option-click that doesn't move changes nothing.
  An Option-drag whose own column closes under it keeps resizing the columns left, and its last
  width still becomes the default.
- **Double-click.** Plain, it fits the column to its widest name, beside a folder's chevron, and
  leaves the default alone. With Option it fits every column and the preview to one width, that
  of the widest name in any column, and sets the default, as an Option-drag does. The preview's
  grip has no names, so its plain double-click does nothing. A column with no rows does nothing.
  The names are measured off the main thread with `NSString.size(withAttributes:)` in the name
  cell's font, from the column's `Listing`, at user-initiated priority; nothing reads the disk.
  A new fit cancels the one running, which stops measuring within 512 names. The result lands
  only on the columns still shown; a fit whose column closed is dropped.
- **Limits.** `Settings.columnWidths` is 100…1000 points: a grip drags no further, and a stored
  default outside it is discarded, and VoiceOver setting a width that isn't a finite number
  stops the app, as a value of the wrong type does. The columns' view is wide enough for the
  last grip's right half. A fit stops at `ColumnViewController.fitWidthCap`, 600 points,
  about two and a half default columns, so one very long name doesn't make a column wider than most
  windows; a drag can still go past it.
- **Default and storage.** `Settings.defaultColumnWidth` is 245, Finder's, and the only copy of the
  number; the old 240 is gone. `Settings.columnWidth` is a number in the app's `UserDefaults` suite,
  read in `Settings` only, like every other preference. A value of another type, a Boolean, NaN or
  out of range is removed and reads as the default.
- **Widths live with the column view, not the session** (superseded 2026-10-24: the pane keeps
  them by folder and the session saves them, see
  [0098](0098-column-widths-per-window.md)). Each column keeps its width while it
  stays in the trail; a new column, and the preview when its view is first made, take the
  default. `TabState` keeps a column-mode pane's focused folder only, not its trail
  ([0041](0041-column-model.md)), so per-column widths would have no column to come back to;
  like the scroll offset, they are view state. Restore, a workspace reload and a snapshot all
  show the default. A resize changes no `WorkspaceState`, so it never sets the edited dot or
  starts a save, and Save Workspace never stores it. Undo holds file operations only
  ([0072](0072-undo.md)), and Finder doesn't undo a resize either.
- **Layout per drag event.** A resize sets the frames that changed: the resized columns', and the
  origins of the views right of them. Only the resized columns' tables change width, so only their
  rows on screen refit their names (`tableViewColumnDidResize`); the columns that only move lay
  out nothing. An Option-drag refits every column's rows on screen, a screen of rows per column.
  Settings is written once, on release.
- **VoiceOver.** Each grip is a splitter, labeled "<folder> column width" (the preview's "Preview
  width"), whose value is the width in points and whose increment and decrement resize its column
  alone by 20 points, posting a value change. The browser's children are each column followed by
  its grip, then the preview and its grip while shown, as a split view's children are panes and
  splitters.

## Alternatives considered

- **A plain drag also sets the default** — not done. The brief asked whether Finder does; Finder's
  preferences hold one width, and `NSBrowser` keeps a single-column resize to that column and
  makes the all-column one the default for new columns. This couldn't be checked against Finder
  itself without opening windows on the main display, so it is one of the checks by hand: if
  Finder's plain drag turns out to set the width of new columns, `endResize` drops its
  `allColumns` condition.
- **Per-column widths in `TabState`** — rejected (superseded 2026-10-24: widths are stored by
  folder, which needs no trail, see [0098](0098-column-widths-per-window.md)): the trail itself
  isn't stored, so a width per
  column would need the columns stored first, a second session format for one view setting.
  Storing one per-pane width would be a third value beside the app default and the live ones.
- **Widths by depth, as `NSBrowser`'s autosave keeps them** — rejected: ← past the first column
  inserts a column at the left, so every width would move to the next folder over.
- **Fit on the main thread** — rejected for B10: a folder can hold tens of thousands of names,
  each measured on its own, and the measuring hasn't been timed. Off the main thread it can't
  stall at any size.
- **Measure with Core Text** — not used: `NSString.size(withAttributes:)` is the measure the
  name's text field takes, and the test compares against the field's own width.
- **`NSBrowser`** — still rejected for the reasons in [0046](0046-column-view.md).

## Consequences

Each window's column widths last only as long as its columns (superseded 2026-10-24: they are
kept by folder and come back after a relaunch or a reload, see
[0098](0098-column-widths-per-window.md)). Relaunching, reloading a workspace
or navigating to a new trail shows every column at the default. An Option-drag in one window
changes the width new columns get in every window, as in Finder, but doesn't resize the columns
other windows show (superseded 2026-10-24: other windows' unresized columns follow the new
width, see [0098](0098-column-widths-per-window.md)). A not-downloaded folder's badge isn't counted in a fit; its name may truncate
by a few points.
