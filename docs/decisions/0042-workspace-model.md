# 0042. Workspace model: tabs own their panes, and TabState is the only Codable form

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.1 puts tabs in Browser: a workspace is an ordered list of tabs, each a `Layout`
([0007](0007-layout-tree.md), [0012](0012-layout-sizes.md)) and the `Pane` for every leaf. The
plan asks that leaves and panes stay equal through every edit, that closing reports a pane, tab or
workspace closed, and that only `TabState` is `Codable`, not `Pane`, with ratios, focus, history
and zoom surviving a JSON round trip. Saving and restoring are M5a's. A pane's Back and Forward
history lives in `Pane` ([0033](0033-history-and-go-to-folder.md)), and in column mode its
location follows the focused column ([0041](0041-column-model.md)).

## Decision

- **`Tab` keeps the layout read-only.** Its edits are the layout's, and split and close add or
  remove the pane in the same call. The rest (focus, move, resize, divider drag, equalize, zoom)
  keep the set of leaves and pass straight through.
- **Split** makes the new pane at the focused pane's location and view mode, in the sort of the
  pane keys act on, with the focused pane's service, settings and system actions. In column mode
  the location is the focused column's folder, so the new pane's trail starts there with one
  column. `Pane.init` takes the view mode, so a column-mode pane starts with its trail and never
  starts a list load of its own. Load priority isn't touched; M3.4 owns it.
- **Close** calls `Pane.close()`: the load is cancelled and the monitor stopped. Closing the last
  pane closes it too and reports `.tab`, leaving the leaf in the layout, since `Layout` has no
  empty state. Closing a tab closes every pane in it. Closing the selected tab selects the one
  after it, or the one before when it was last. Closing the last tab reports `.workspace` and
  leaves the tab in place, so `selectedTab` is never optional; the caller drops the workspace.
- **A closed tab traps.** Once its last pane closes, or `close` runs, `focusedPane`, `state`,
  `split`, `closePane`, `close` and every layout edit fail with a precondition that says to drop
  the tab. Otherwise a split would build a live pane from a closed one. `Pane.close()` also drops
  its column trail, so a closed column-mode pane's `commandPane` is the pane itself, not an index
  into an empty trail.
- **Add** puts the new tab right after the selected one and selects it. **Move** takes the index
  counted after the tab leaves its place; the selection stays on the same tab.
- **What `TabState` captures.** The layout as `Layout` encodes it (tree, ratios, focused pane,
  focus history, zoom), and for each pane its location path, view mode (`list` or `column`), and
  Back and Forward entries, each a path and the name under the cursor there. Nothing else: no
  rows, selection, filter, sort, scroll position, or columns other than the focused one.
- **Only `TabState` is `Codable`.** It encodes the panes in the layout's order through private
  stored types, so `Location`, `ViewMode`, `History` and `ExactName` gain no `Codable`
  conformance and `Pane` none. `History` became `Equatable` and exposes its two stacks and an
  initializer taking them; `Pane.history` became readable inside Browser.
- **Mismatches fail loudly.** `TabState.init` traps unless its pane states match the layout's
  leaves. Decoding throws `DecodingError.dataCorrupted` for a duplicate pane or panes that don't
  match the leaves, as `Layout` does for its own invariants.

## Alternatives considered

- **Make `Location`, `ViewMode` and `History` `Codable`** — rejected: the plan says only
  `TabState` is, and each would gain a stored shape that M5a would then have to keep stable.
- **A second split model holding panes in its leaves** — rejected: `Layout` already is the split
  tree, and keying panes by `PaneID` keeps it a plain value.
- **Remove the last tab and make `selectedTab` optional** — rejected: every tiling command would
  unwrap it for a state that lasts only until the window closes.
- **Give the new pane focused load priority on split** — not now: M3.4 decides how focus moves
  the queue, and setting it here would leave the old pane focused too.

## Consequences

A pane restored from `TabState` (M5a) starts with a one-column trail in column mode, at the
folder that was focused, and can pass the view mode to `Pane.init`. A tab whose `closePane`
returned `.tab` holds a closed pane and traps on use; the caller must drop it.
