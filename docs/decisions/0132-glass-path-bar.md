# 0132. The path bar floats in a glass capsule over the bottom of each pane

- **Date:** 2026-10-28
- **Status:** accepted
- **Amends:** [0026](0026-path-bar.md) (the bar's own row along the pane's bottom),
  [0052](0052-pane-status.md) (the status's 60% is of the capsule, not the pane)

## Context

Dylan, 2026-10-28, after [0128](0128-finder-window-chrome.md) gave the window Finder's glass
toolbar: "can the breadcrumbs area also use liquid glass style UI". His screenshots of Finder
(`tmp/shots/fb-1028b-2.jpg`, `fb-1028b-3.jpg`) show the toolbar's items as rounded translucent
capsules floating over the content, which scrolls under them.

Each pane's path bar (0026) sat in its own 28-point row along the pane's bottom, with the status
(0052) at its end, and the list or the columns ended where the row started.

## Decision

- **One glass capsule per pane.** `PaneViewController.pathBarGlass` holds the path bar and the
  status, as they were laid out in their row: the bar from the leading end, the status at the
  trailing end taking at most 60% of the capsule. From macOS 26 it is the system's
  `NSGlassEffectView`, `.regular` style, with a corner radius of half the bar's 28 points, so the
  ends are round as the toolbar's capsules are. The palette uses the same view for its panel
  ([0087](0087-palette-window.md)). Before macOS 26 it is a `.headerView` blur in the same
  shape. The glass is made once with the pane's views; a new location replaces only the segments
  in it, as before.
- **It floats.** The capsule sits `PaneViewController.pathBarGap`, 8 points, in from the pane's
  sides and bottom. The list and the columns run under it to the pane's bottom, so rows scroll
  under the glass as Finder's content scrolls under its toolbar. The gap is measured from the
  pane's bottom, which sits above the window's status bar (SB.1) while that shows; the status
  bar is outside the panes, and rows don't scroll under it.
- **Drags pass through it.** The glass's content, `PathBarGlassContent`, takes the drag types
  the list's table takes and hands every drag call to the clip view of the list, or of the
  column, under the drag (`ColumnViewController.listClip(under:)`); the clip passes it to its
  table as it does for a drag in its margins (0029). So the row under the glass highlights,
  spring-loads and takes the drop as it would with no glass over it. Each update the glass gets
  also scrolls that list down a row, until its end: a drag held at the bottom of a full list
  scrolls to the rows below, as one held at the bottom edge of Finder's list does. The table's
  own autoscroll never sees the drag there, since AppKit hands it to the glass. Over the
  preview a drag goes nowhere, as the preview takes no drops.
- **The last row stays reachable.** `PaneViewController.pathBarCover`, the bar's height plus the
  gap, is how much of the pane's bottom the glass covers. The list's and each column's clip view
  add it to the bottom margin (`ListingViewController.keepMargins`), so the last row scrolls to
  `Margin.standard` above the capsule and `scrollRowToVisible` keeps a row clear of it. Their
  scrollers end above it (`scrollerInsets.bottom`), as do the columns' sideways scroller and the
  preview's content and scroller (the preview's `contentInsets`). Go to Item centers a row in
  the room between the header and the glass. The access and error messages center in that room
  too. The first row sits where it did, below the header.
- **The focused pane's bar** keeps BC.1c's look on the glass: its titles are `labelColor`, every
  other bar's `secondaryLabelColor`, with the same rules for when (0026). The glass vibrancy
  draws both, so the focused bar reads darker and the others lighter in either appearance. The
  glass itself is the same for every pane.
- **What stays.** Segments, clicks, Cmd-clicks, the hover, pressed and focus looks
  ([0110](0110-interaction-states.md)), truncation and the expanding segment are the path bar's
  own and unchanged: the bar is the same view, at the same height, inside the capsule. A click
  on the capsule outside a segment goes up to the pane container, which gives the pane the keys,
  as a click on the bar's empty part did. The spinner and the note are the status view's, in the
  capsule. VoiceOver reads the bar's "Path" group and the status as before; the glass is not an
  element.
- **Performance.** One glass view per pane, never rebuilt. Glass over a scrolling list samples
  what is behind it each frame it moves; a single 28-point capsule per pane is the smallest that
  can do. The UI bench's scroll scenarios measure it.
- **Bench owed.** No bench ran for this change: the UI bench's scroll scenarios over a 100k-row
  list, with the glass showing, are still to run.

## Alternatives considered

- **Keep the bar in its own row, in glass** — rejected: the capsule would sit on the pane's own
  background, with nothing behind it to blur, and read as a grey box. Dylan's screenshots show
  glass over content.
- **A capsule that hugs the segments**, as Finder's toolbar capsules hug their items — rejected
  for now: the status needs its own place, which means a second glass view per pane, and the
  capsule's width would change on each location change. One capsule across the pane keeps
  0026's truncation and 0052's 60% as they were.
- **Clear glass (`.clear`) for the unfocused panes' bars** — rejected: clear glass over moving
  rows leaves secondary-colored titles hard to read, and the difference would show only where
  rows are behind the bar.
- **A tinted capsule (`tintColor`) for the focused pane** — rejected, as 0026 rejected a tinted
  background: new chrome where the ring already marks the pane in a split.
- **Hand-drawn glass** (a rounded fill with a blur layer) — rejected: it would drift from the
  toolbar's glass, as 0128 says of the toolbar.

## Consequences

- A drop below the last row still lands in the folder shown, in the margin above the capsule.
  A drop on the capsule lands on the row under it, or in the folder shown where no row is.
- A drag over the capsule scrolls the list a row at each update AppKit sends, at one speed
  however near the bottom it is, while Finder speeds up nearer the edge.
- The column resize grips run the column's full height; their bottom 36 points are under the
  capsule, which takes the mouse there. The grips are still reachable above it.
- Rows don't scroll under the toolbar. The tab strip and the config banner sit between the
  toolbar and the panes (0128), so the rows would scroll under the tab strip, not the toolbar.
  **Dylan to say** whether the tab strip should go glass too, which that would need.
- Tests can't capture the glass (0128): they check that the bar and the status are in an
  `NSGlassEffectView`, the capsule's frame, the rows' and scrollers' insets, the titles' colors
  and that a click at a segment reaches it. The look needs a check by hand.
