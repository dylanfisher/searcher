# 0053. Column accessibility: a browser of named columns, a spinner per column, announced notes

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M2.8 makes column view ([0046](0046-column-view.md)) read like a browser with VoiceOver: columns
by folder name, rows by name and kind, and a move to another column or a share going offline
announced. Each column's row labels already came from the list's builder
([0040](0040-list-accessibility.md)), formatted from the entry for the parts a names-only column
doesn't show. The pane's spinner and its slow or offline note sit in the path bar and follow the
focused column ([0052](0052-pane-status.md)); a column had no spinner of its own. A table that
takes the keys is reported to VoiceOver by AppKit. The pane's view controller gives the focused
column's table the keys after → and ←, after `ColumnViewController.paneDidChange` has run.

## Decision

- **The columns are a browser.** The column view's document view is an accessibility element with
  the browser role, and its children are the columns' scroll views, left to right. The list is
  set explicitly on the first show and again whenever the columns change, compared against the
  list last set: until a list is set, AppKit gives the view's shown subviews, so a shown spinner
  would read as an unlabeled child between two columns. Each column's scroll view is labeled
  with its folder's name, as is its table. This is the shape VoiceOver knows from `NSBrowser`: a
  browser, then scroll areas, then lists. Separators and spinners aren't children.
- **Row labels are the list's.** Nothing new: a test checks that a column's labels equal the
  list's for the same folder, word for word.
- **A focus change is posted once per change.** When the trail's focused column changes,
  `ColumnViewController` posts `focusedUIElementChanged` on that column's table. It posts nothing
  for the first column shown, for a selection change inside the focused column, or when a
  table's taking the keys moved the focus, since AppKit reports that itself.
- **The note is announced when it changes kind.** When the status view's note appears, turns
  from slow to offline or back, or names another volume, it posts `announcementRequested` with
  the note's text at high priority. A pane that stays offline isn't announced again as its rows
  age or as more updates arrive, and one that loads and goes offline again is.
- **A spinner per column.** Each column has a small spinner in its bottom-right corner, 6 points
  from the edges, shown on the same rule as the status view's (`PaneStatusView.isInFlight`, after
  `LoadTimeouts.spinnerDelay` on an injected clock). The focused column's spinner and the path
  bar's show together.
- **Posting is injected.** `ColumnViewController.postAccessibility` and
  `PaneStatusView.postAccessibility` default to `NSAccessibility.post`, as `FilterBarView`'s does.

## Alternatives considered

- **Make the outer scroll view the browser** — not done: overriding an `NSScrollView`'s role and
  children drops its scroller, and the document view already holds exactly the columns.
- **Post no focus change of our own and rely on AppKit's** — rejected: a focus change that
  doesn't move the keys would go unheard, and the column view can't see whether the keys move.
- **Skip the post when the keys will follow** — not done: the keys move after `paneDidChange`, so
  the column view can't tell yet. VoiceOver may hear the focus change twice on → (ours, then
  AppKit's for the same table); Dylan's check says whether that repeats anything.
- **A status view per column** — rejected: each would show the note and announce it, so pulling
  a share would read "music is offline." once per column.
- **Center the column's spinner over its rows** — rejected: it would cover the rows of a column
  with cached rows refreshing.

## Consequences

The focused column shows two spinners while it loads, its own and the path bar's. Column
spinners aren't reachable by VoiceOver; the path bar's, labeled "Loading <folder>", is. Two
panes on the same share each announce going offline. A column whose folder can't be listed still
shows an empty table with no message; only its spinner state is per column. The posting closure
is now in three views (the filter bar, the column view and the status view); sharing it is a
promotion for its own commit.
