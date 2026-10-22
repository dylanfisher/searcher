# 0014. Layout view dividers: drag area, cursors and accessibility

- **Date:** 2026-10-20
- **Status:** accepted

## Context

`0007-layout-tree.md` has one frame-based view render the layout, so the divider cursors, drags
and accessibility that `NSSplitView` gives for free are written by hand. `0012-layout-sizes.md`
draws the divider in 1 pt and leaves Interface free to make its drag area wider. VoiceOver has to
announce each divider and move it, and the cursor and VoiceOver can only be checked by hand.

## Decision

- `PaneLayoutView` sets pane frames in `resizeSubviews(withOldSize:)` and when its layout is set,
  not in `layout()`, so frames follow a size change at once and tests need no layout pass.
- The drag area and cursor rect reach 3 pt past each side of the 1 pt divider. The view takes
  clicks there through `hitTest(_:)`, since the panes beside it overlap that area.
- A drag converts the pointer to a ratio with `Layout.Divider.ratio(at:)` and calls
  `Layout.setRatio(_:at:in:)`, which clamps it to the minimum pane size.
- Each split has one `DividerAccessibilityElement` with the splitter role. Its orientation is the
  divider line's, as with `NSSplitView`: side-by-side panes have a vertical splitter. Its value is
  the split's ratio, described as a percentage, and it can be set. Increment and decrement move
  the divider 40 pt, the tiling commands' step. Elements are kept by split path across layout
  changes, so VoiceOver stays on the divider it moves.
- The two-pane fixture for the hand check is a test in `PaneLayoutViewTests` that runs only when
  `SEARCHER_LAYOUT_FIXTURE` is set. It shows a window on the secondary display without activating
  and returns when the window is closed, so the app's wiring has no fixture mode.

## Alternatives considered

- **Pane frames in `layout()`** — rejected: a frame change only marks the view for layout, so
  tests would have to force a pass, and the frames lag the size until the next one.
- **The value in points, as an offset from the split's start** — rejected: the number changes
  with the window size for the same layout, and VoiceOver would read a bare point count.
- **A launch argument in `Sources/Searcher`** — rejected: it adds a mode to the app that only one
  manual check uses.

## Consequences

The 40 pt step is defined in `DividerAccessibilityElement` until the tiling resize commands exist;
they and the element should then share one constant in Browser. The fixture window belongs to the
test process, so cursor rects work only after a click makes it key.
