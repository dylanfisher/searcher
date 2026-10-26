# 0046. Column view: one names-only list per column, side by side

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M2.6 gave a pane a column mode: a `ColumnTrail` whose columns each hold a `Pane`
([0041](0041-column-model.md)). M2.7 shows it. Column view has to feel like the list on a share
(B6, key → selection moved, 16 ms), so it needs the list's row refresh in place
([0029](0029-row-movement.md)), shared type icons ([0004](0004-listing-view.md)), the
not-downloaded badge ([0030](0030-not-downloaded-badge.md)), row labels
([0040](0040-list-accessibility.md)), type-select ([0034](0034-type-to-select.md)), Quick Look
([0032](0032-quick-look.md)) and the filter ([0037](0037-type-to-filter.md)). The plan picked
stacked single-column tables over `NSBrowser`.

## Decision

- **Each column is a `ListingViewController`** over its column's pane, built with
  `showsNamesOnly`: the Name column alone, no header, no alternating rows, no horizontal scroller.
  (Amended 2026-10-25: a column scrolls vertically only, as in Finder; only the browser scrolls
  sideways. A plain `NSScrollView` kept a sideways gesture over a column and bounced its rows
  sideways, chevrons and all, and nothing put back a table column wider than the clip, so a
  chevron could end up past the column's edge. A column's `ColumnScrollView` has no horizontal
  bounce, a clip view that keeps its bounds at x = 0, and sizes the table's column to the
  visible width whenever the table's or the clip's frame changes, so the table is never wider
  than what shows of it and the chevron sits at the column's visible right edge for any name, at
  any width down to the minimum. A sideways trackpad gesture over a column, decided by its first
  move as over a grip, and a wheel's sideways click go up to the columns' scroll view. A long
  name truncates in its middle before the badge and the chevron, as Finder's does.)
  Everything else (rows, icons, badge, labels, selection, Quick Look, Page Up and Down through
  `visibleRowCount`) is the list's code. Row labels read the cells the table has and format the
  kind, size and date from the entry for the columns it doesn't.
- **The columns bounce sideways always.** The scroll view holding the columns has horizontal
  elasticity `.allowed`, so a swipe sideways overscrolls and springs back even when every column
  fits, as a short column does vertically (2026-10-25). (Amended 2026-10-26, Dylan: "column
  vertical bounce should only be within the single pane, not the whole viewport area." That
  scroll view's vertical elasticity is `.none`, so a vertical overscroll never moves the whole
  view. Each `ColumnScrollView` bounces vertically (`.allowed`), even when its rows fit, as
  Finder's columns do.)
- **`ColumnViewController`** lays the columns out with frames in a horizontal scroll view, 240
  points each with a separator line after each (superseded 2026-10-24: each column has its own
  width, 286 points for a new one, see [0096](0096-column-widths.md)). On every change of the pane it keeps one
  controller per column, matched by pane, so a column's table and its scroll position survive
  → and ←; it adds a controller for each new column and starts its folder monitor, and drops the
  controllers of closed columns. When the focus or the column count changes it scrolls the
  focused column into view, with the column right of it where that fits; a selection change
  inside a column doesn't scroll. (Superseded 2026-10-24: the scroll is animated, 0.25 seconds
  through the clip view's animator, which a new target retargets from where it is, so a held →
  or ← never queues one. The rows and the selection are set before it starts, so B6 doesn't
  change. It jumps for the first show, a new trail with no column kept (a restore, a workspace,
  a Go to folder), a resizing drag and Reduce Motion.) (Amended 2026-10-25: AppKit runs the animator on display refresh, so with the display asleep it never ends. `moveClip` takes the animation as a parameter, `animateClip` by default; tests pass a stand-in that records each target and ends the latest on demand, and none waits on a real animation.) (Amended 2026-10-25, Dylan: "when i move
  up or down in selection the whole pane flashes and jumps scroll horizontally to left, then
  moves back over to right." A ↓ made by keys drops the column right of the selection, or
  clears the preview, at once and opens the next one once the keys pause
  ([0094](0094-column-open-delay.md)). The columns' view was sized to its columns, so at the
  right end it narrowed and the clip view clamped the scroll left, and the column or preview
  that came back scrolled it right again. The columns' view is now no narrower than the right
  edge of what it shows, so a column or preview that closes or narrows never scrolls the view,
  and one that opens in its place needs no scroll. The room left past the columns goes as the
  view scrolls it out of sight: the controller resizes the view on each move of the clip view's
  bounds. That only ever narrows it: the room kept is never more than the view already has, so
  a rubber-band past the right end, whose bounds reach past the view, widens nothing. The same keeps a grip under the pointer in a drag at the right end, where the clamp
  used to slide every column left of the grip and leave the view scrolled after a drag back.)
  (Amended 2026-10-25: a trail now starts at the root of its folder's volume, so a new trail
  is scrolled from the left end: the focused column, with the one right of it where that fits,
  ends at the right edge and the columns above it fill the view to its left. A trail shown
  before the view had a width scrolled to nothing, so the view scrolls again, once, when it
  first gets one. See [0103](0103-column-trail-from-the-root.md).) (Amended 2026-10-25: a
  navigation, Back or Forward that starts the trail again keeps the columns both trails show,
  so the view keeps their controllers and animates the scroll from where it is; only a trail
  from another root, which keeps none, jumps. See [0103](0103-column-trail-from-the-root.md).)
- **`PaneViewController`** holds the list and the columns in the same place and shows one by the
  pane's view mode. It builds `CommandContext` with `commandPane`, the filter field calls
  `setFilter` on it, and Quick Look toggles the focused column's controller. The path bar and Go
  to folder keep the pane, which navigates. (Amended 2026-10-25: a path bar click on a folder
  whose column shows moves the focus to that column instead, `Pane.showFolderAbove`, closing the
  columns right of it; see [0103](0103-column-trail-from-the-root.md).) It starts no monitor for
  the pane in column mode, and starts the list's again when the list comes back.
- **The keys follow the focus.** If one of the pane's tables had the keys, the focused column's
  table takes them after → and ←, after a switch of view mode, and after the column that had them
  closes. A table that takes the keys by a click focuses its column (`ColumnTrail.focus`), and
  that change doesn't move the keys again.
- **The filter field shows the focused column's filter.** Moving to another column shows that
  column's text, or hides the field when it has none. The field is emptied before it gives up the
  keys, so its end-of-editing action can't send the old text to the pane now in front.
- **Overlays are the list's only.** The spinner (superseded: it moved to the path bar row and
  shows the focused column's state, see [0052](0052-pane-status.md)), the access explanation and
  the error line stay hidden in column view; the pane holds no rows there. Each column also
  shows its own spinner, see [0053](0053-column-accessibility.md).
- **View menu.** as List (Cmd-1) and as Columns (Cmd-3) head the View menu, with a check mark on
  the pane's mode. The check comes from `CommandBinding.isCurrent`, which reads the pane through
  the command context, since view mode is per pane while `isChecked` reads app-wide `Settings`.
- **Spring-loaded folders** (amended 2026-10-24). A drag that hovers over a folder row in a
  column selects the folder once the system's spring-loading delay passes, so its column opens
  to the right at once, without the keys' pause, and the drag can go on into it. The selection
  is no step of the selection history. Once the drag ends, each column still in the trail takes
  back the selection it had and the focus goes back to its column. See
  [0099](0099-get-info-and-spring-loading.md).

## Alternatives considered

- **`NSBrowser`** — rejected in the plan: its matrix-based cells don't take the list's view-based
  cells, refresh in place, badge or labels, so each would be built twice.
- **One table per column without `ListingViewController`** — rejected: a second copy of the row,
  selection and Quick Look code.
- **Auto Layout or an `NSStackView` for the columns** — not used: the columns have one fixed
  width, so a frame per column is all the layout there is, and it is set only when it changes.
- **Rebuild the column controllers on each change** — rejected: a table rebuilt per arrow key
  loses its scroll position and makes a screen of row views again.
- **Set the check marks in `MainMenuBuilder.showChecks`** — rejected: it observes `Settings`,
  and the view mode belongs to the focused pane, which only the table validating the item knows.

## Consequences

Columns are a fixed 240 points wide and can't be resized (superseded 2026-10-24: a grip along
each column's separator resizes it, Option-drag resizes every column and a double-click
fits the widest name or goes back to the default; a new column is 286 points, or the width the last
Option-drag or Option-double-click set, see [0096](0096-column-widths.md)). There is no preview column
(superseded 2026-10-24: one selected file in the last column shows a preview to its right, see
[0090](0090-preview-column.md)). A folder row shows no disclosure
chevron (superseded 2026-10-24: a folder row shows Finder's right-aligned `chevron.right`, a
template that is white on a selected row in the focused column and secondary gray otherwise;
files, packages and links show none, since the listing holds no link target and resolving one
would be a read, and a name is fitted to end before the chevron). A column whose folder can't be
listed shows an empty table with no message; only the spinner is per column ([0053](0053-column-accessibility.md)).
(Superseded 2026-10-24: a column with no rows to show says why in its middle, in the list's
words from `PaneViewController.message(for:)`, `AccessDeniedView` and `PaneStatusText`. Denied
shows the access explanation and its button, since the fix is Searcher's Full Disk Access, which
Finder doesn't need. Failed and missing show the list's error line. Slow and offline with no rows
kept show the status note, which the path bar shows only for the focused column; with rows kept
they show the rows, as the list does. A filter that matches nothing shows the list's line. An
empty folder's column is blank and a loading one shows only its spinner, as in Finder. →
into a column whose rows haven't arrived selects its first row once the whole folder's rows
do: a full listing or cached rows, not a first batch, whose first row needn't be the folder's.
It selects without the key flag, so a folder there opens its column at once. A selection in that
column, ←, a focus change, the pane losing the keys or navigating first gives that up, as do
rows that land empty and a folder that can't be listed. Show Package Contents selects nothing
in the package's column, as in Finder. VoiceOver doesn't read a column's message yet: the browser's
children are the columns only.) A column's table carries the list's
`ListingViewController`, so changes to the list's rows reach columns too; a change meant for the
list only has to check `showsNamesOnly`.

Holding ↓ through a column of folders costs more per row than in the list: each folder row
makes a new column controller and table, starts that column's folder monitor at once, and
closing the column before stops its monitor on the main thread through `Pane.close`. M2.11
measures this in its column-view B6 case. If it misses the budget, the first fix to try is
starting a column's monitor only after its first rows land, so a column passed over by a held
key never starts one. (Superseded 2026-10-24: a key-made selection opens its column only once the
keys pause, so a held key makes no column, and no monitor, per row; monitors still start with
their column, see [0094](0094-column-open-delay.md).)
