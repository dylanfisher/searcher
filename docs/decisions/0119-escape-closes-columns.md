# 0119. Escape closes the columns past the selected folder's

- **Date:** 2026-10-27
- **Status:** accepted
- **Amends:** [0041](0041-column-model.md) and [0103](0103-column-trail-from-the-root.md),
  where they say ← keeps the columns to the right.

## Context

Dylan, 2026-10-27: "when you are deeply nested into a directory in column view, then move left,
you still see open columns in the right. lets make it so if you press escape it closes the
columns to the right and removes focus from all but the current selection (and left columns)".

← keeps the columns to the right ([0041](0041-column-model.md)), so → goes back into the same
folder. After a few ← the view still shows every column down to where the keys were, each with
its old selection. A press on the selected row already trims them
(`ColumnTrail.showNextColumnAlone`, 0041); the keyboard had no way to. Escape had no meaning in
a column's table, except in a server's column while a share mounts, where it lets go of the
mount ([0115](0115-server-shares.md)). Finder's column view does nothing on Escape
*(unverified)*; this is Dylan's request, not Finder parity.

## Decision

- **What Escape keeps.** With the keys in column k and row R selected there, Escape keeps the
  columns up to k with their selections, the trail to R. When R is a folder (or a package whose
  contents column is open), the column showing R's contents stays, since it is R's own and
  would open again at once, but its selection is cleared. Every column past that one closes, and
  so does the preview of a file selected in one of them. This is what a press on R does, so
  Escape calls the same code (`ColumnTrail.closeColumnsPastNext`, which runs
  `showNextColumnAlone`).
- **When there is nothing to close.** When no column is open past R's, and R's column has
  nothing selected, or when nothing is right of column k at all (R is a file and its preview
  shows, R is several rows, or k is the last column), Escape changes nothing and goes on to
  `super`, as before.
- **The keys stay.** Column k keeps the keys. Escape isn't a navigation: it records no step of
  Back, moves no keys between columns, and so records no Cmd-U step either
  ([0112](0112-position-history.md)); clearing the selection in R's column is no step, as with
  the press. Cmd-U after Escape undoes the ← before it: the column the keys left gets them back
  with its selection, and the column that selection opens comes back.
- **What the window saves.** A tab saves the focused column's folder and its selection, not the
  columns right of it (`TabState`). Escape changes neither, and a restored trail opens R's
  column with nothing selected in it, which is what Escape leaves. Column widths are by folder
  and don't change.
- **Precedence.** Keys go through the command registry first ([0010](0010-command-registry.md));
  no command is bound to Escape. Then `ListingTableView.escape` runs: a share mount the pane
  waits for is let go of first, otherwise the columns close. The two can't both apply: a column
  waiting for a mount has the unmounted share selected, which opens no column right of it.
  The filter bar, the rename field, the preview's text, Quick Look's panel and the sidebar take
  Escape themselves before it reaches a column's table, and keep doing so.
- **List view** is unchanged: `closeColumnsPastNext` returns false for a pane that isn't a
  column.

## Consequences

Escape now does something in column view whenever a column is open past the selected folder's,
including after a click left of the focused column, not only after ←. A second Escape does
nothing. ← still keeps the columns to the right; Escape is the way to drop them without the
mouse.
