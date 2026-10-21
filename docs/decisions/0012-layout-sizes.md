# NNNN. Layout sizes, pane IDs and zoom

- **Date:** 2026-10-20
- **Status:** accepted

## Context

`0007-layout-tree.md` puts the split tree in Browser with a minimum pane size, and has split and
resize take the container size. It leaves open the size itself, how resize and equalize behave
when a nested split is in the way, what names a pane, and what happens to zoom when focus moves.
Spike S5 found 6 negative frames in 200 random layouts and drew 1 pt dividers.

## Decision

- `Layout.minimumPaneSize` is 120 pt and `Layout.dividerThickness` is 1 pt, both defined once in
  `Layout`. Geometry functions take only the container bounds; Interface draws the divider in
  that 1 pt and can make its drag area wider without changing the model.
- Split refuses (returns `nil`) when either half of the focused pane would be under the minimum.
- Resize moves a divider by points, not ratio, so the 40 pt step in the tiling commands means
  40 pt at any window size. Resize, divider drags and equalize clamp each split so that each
  child keeps the smallest extent its subtree can shrink to, then refit the splits inside it.
  Pushing a divider toward a nested split squeezes that split's panes to the minimum.
- Equalize gives each pane in a run of same-axis splits the same extent with dividers counted,
  not the same ratio, so three side-by-side panes come out exactly equal.
- `PaneID` is a UUID, encoded as a bare string. Panes made in different windows never collide,
  and a saved layout needs no ID counter.
- Zoom is a `Bool` on the focused pane. Focusing another pane, split, close, move, resize, drag
  and equalize all end it, so the tiling commands get "unzoom first" from the model.
- Decoding checks the invariants (each pane once, history lists every pane with the focused one
  first, ratios between 0 and 1) and throws `DecodingError.dataCorrupted` on a mismatch.

## Alternatives considered

- **Divider gap as a parameter, as in S5** — rejected: split and resize would need the same gap
  as the view, and every caller would pass it, a second copy of one number.
- **Clamp ratios to a fixed range (S5's 0.1–0.9)** — rejected: 10% of a small window is under any
  useful pane width, and 10% of a wide one wastes space.
- **Clamp each split against its subtree's current ratios** — rejected: a divider would stop at
  the first nested pane to reach the minimum instead of pushing the nested divider.
- **Int pane IDs from a counter** — rejected: the counter would have to be saved with the layout,
  and a tab torn out into another window would need renumbering.
- **Zoom stored as a pane ID** — rejected: focus could move to a pane hidden under the zoomed one.

## Consequences

The tree fits only bounds at least as large as its minimum. When the window is smaller, frames
come out under the minimum and edits leave the splits that can't fit unchanged. Keeping the window
at least that large needs the tree's minimum size from the model, which this step doesn't expose
yet. Changing the minimum pane
size or the divider thickness is a one-line edit in `Layout`.
