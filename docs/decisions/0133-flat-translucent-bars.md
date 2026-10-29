# 0133. Flat translucent bars: the path bar's own row again, and rows under a compact toolbar

- **Date:** 2026-10-28
- **Status:** accepted
- **Amends:** [0128](0128-finder-window-chrome.md) (the toolbar's style, and content hanging
  below the bar), [0132](0132-glass-path-bar.md) (the floating capsule)

## Context

Dylan, 2026-10-28, after [0132](0132-glass-path-bar.md) floated each pane's path bar in a glass
capsule: "keep the breadcrumbs closer to how they were before. we just want the translucent glass
effect on the container, but not the rounded floating aeshetic. the title bar on top header should
be shorter and have the translucent glass look". His screenshots of Finder's macOS 26 window
(`tmp/shots/fb-1028b-2.jpg`, `fb-1028b-3.jpg`) show a shorter toolbar than Searcher's, rows
scrolling under it blurred, and a flat bottom bar with the content blurred under it.

The window had the unified toolbar, 52 points tall, and the tab strip, the config banner and the
panes hung below it from the content's safe area (0128), so nothing scrolled under it.

## Decision

- **The path bar's row is back, translucent.** `PaneViewController.pathBarGlass` is a flat
  `NSVisualEffectView`, `.headerView` material, blending within the window: 28 points tall, the
  pane's full width and flush with its bottom, square, as 0026's row was. The list and the
  columns still run to the pane's bottom under it, so the rows show through it blurred. It holds
  the path bar and the status as 0132's capsule did. `pathBarGap` is gone, and
  `pathBarCover`, the part of the pane's bottom the row covers, is the bar's 28 points. The row
  draws no line above it.
- **What 0132 keeps.** Drags over the row go on to the list or the column under it, with
  spring loading and the row-at-a-time scroll; the last row scrolls to `Margin.standard` above
  the row; the scrollers, the preview's end and the centered messages stay above it; Go to Item
  centers above it; the focused pane's titles are `labelColor`, the others `secondaryLabelColor`.
- **The compact toolbar.** The window's `toolbarStyle` is `.unifiedCompact`: the bar is 40 points
  tall instead of 52, with the same items, Back and Forward's glass group and the view modes. With
  the toolbar hidden the title bar is 32 points in either style.
- **Rows under the toolbar.** On macOS 26 the config banner and the tab strip are top accessories
  of the panes' split view item (`NSSplitViewItemAccessoryViewController`), as the status bar is
  its bottom one (0131): the system draws them in the toolbar's band and takes them out of the
  panes' safe area. The tab host then runs to the window's top, under the toolbar, the banner and
  the strip, so the rows scroll under all three, behind the system's scroll edge effect. A
  hidden banner or strip hides its accessory, which takes its room away.
- **The first row starts below them.** Each pane reads the part of its top that the bars cover
  from its safe area (`PaneViewController.topCover`) whenever it lays out, so a toolbar shown or
  hidden, a strip that comes or goes with the second tab, and the banner all move it. It gives
  the cover to the list, to each column and to the preview (`ListingViewController.topCover`,
  `ColumnPreviewView.topCover`). The list sets its scroll view's top inset to the cover, which
  moves the header and the scroller below the bars, and its clip's top inset to the cover, the
  header and the margin, so at rest the first row is where it was and `scrollRowToVisible` keeps
  a row clear of the bars. A list at its top stays at its top when the cover changes.
- **Dragging up.** The clip's top edge lies under the toolbar, which takes a drag there, so
  AppKit's autoscroll never sees a drag past it. A drag held within a row's height below the bars
  and the header scrolls a covered list up a row each update, as one held over the path bar's
  row scrolls it down (0132). The
  scroll views no longer take AppKit's automatic insets: the pane says how much is covered.
- **Only what is under the bars.** A pane below another in a split is not under them: its safe
  area starts at its top and its cover is 0. With the filter bar shown, the bar sits at the safe
  area's top and the list starts under it, uncovered; closing it runs the list under the toolbar
  again.
- **Before macOS 26** the banner and the strip hang from the safe area as before and the panes
  start below them; the path bar's row is the same.
- **States.** The toolbar's items, the strip's segments and the path bar's segments keep their
  hover, pressed, focus and disabled looks, all the system's or 0110's; nothing here draws a
  control.

## Alternatives considered

- **`NSGlassEffectView` with no corner radius** for the path bar's row — rejected: glass draws
  its own edge highlight and depth, which reads as a slab laid over the list, the floating look
  Dylan asked to drop. A material is flat.
- **The tab strip as a view over the panes with a material behind it**, sized by hand into the
  panes' safe area — rejected on macOS 26: the split view item's accessories do the same in the
  system's own band and safe area, as the status bar already does.
- **Keep the unified toolbar's height** — rejected: Dylan asked for a shorter bar.
- **Each list reading its own safe area** — rejected: a column's list sits inside the columns'
  scroll view, and a list under the filter bar would need its own rule; the pane knows both.

## Consequences

- The tab host is the window's content height now, so a split's ratios are of a taller area.
- A pane split from another copies its scroll origin
  ([0061](0061-split-keys-and-grid-layouts.md)). A scrolled pane under the toolbar copied into
  one below it shows its rows offset by the cover, the toolbar's and strip's height at most.
- The rows under the toolbar still count as on screen, so their icons and thumbnails load.
- The columns' resize grips and separators run up under the toolbar, where the toolbar takes
  the mouse; the grips are reachable below it.
- Tests can't capture the material or the scroll edge effect (0128). They check the row's frame
  and material, the toolbar's style, the covers, the insets and where the first row lies with
  the toolbar shown and hidden, with a tab strip, the banner, a split and the filter bar. The
  look needs a check by hand.
- None of it shows in an app linked against an older SDK, which AppKit draws with the old look.
  The first build of this step was, and showed opaque bars
  ([0134](0134-link-against-the-current-sdk.md)).
