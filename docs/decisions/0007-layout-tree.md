# 0007. Layout tree in Browser, rendered by one frame-based view

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Tiling is a must, and dual pane is the same split tree with two leaves. The
tree has to restore with a workspace, answer "which pane is to the left", and render without
drifting from the saved ratios. Spike S5 built the model without AppKit and compared two ways to
render it (spike S5).

## Decision

The layout is a value type in Browser: a binary split tree with ratios, the focused pane, focus
history and zoom. It computes pane frames and divider rects for a given size, enforces a minimum
pane size, and is `Codable`. Interface renders it with one view that sets pane frames from the
model and draws and drags dividers itself.

## Alternatives considered

- **Nested `NSSplitView`s** — rejected: they drifted 250–470 pt from the model on window resize
  and in deep trees, logged ambiguous layout, and took up to 17 ms per change at 9+ panes, against
  under 1 ms for the frame view.
- **Geometry in Interface** — rejected: focus-by-direction and "other pane" then need a window to
  test; in the model they're covered by plain unit tests.

## Consequences

Divider cursors and divider accessibility elements are written by hand. The model uses its own
`Rect`, since Foundation alone doesn't expose `CGRect`'s members. Split and resize take the
container size to enforce the minimum pane size.
