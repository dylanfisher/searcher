# 0044. Tiling commands: model only, kept out of the app until the window has a workspace

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.2 makes the Tiling keys in `tmp/behavior.md` commands on the selected tab: split right and
down, focus, move and resize by arrow, zoom, equalize, and close pane (Cmd-W). Commands get what
they act on from `CommandContext` ([0032](0032-quick-look.md), [0033](0033-history-and-go-to-folder.md),
[0037](0037-type-to-filter.md)). Split and resize need the container's bounds
([0012](0012-layout-sizes.md)), and closing reports a `CloseResult` that only the window can act
on ([0042](0042-workspace-model.md)). The window still shows one pane, and `PaneViewController`,
which builds the context for every key, has no workspace; M3.5 builds the window with tabs and
splits. Cmd-W is the chord of Window's Close Window item, so registering a command on it fails
the menu build ([0027](0027-key-dispatch.md)).

## Decision

- **The context.** `CommandContext` takes an optional workspace, a `tabBounds` closure and a
  `didClosePane` closure. `workspace` and `tab` (the selected tab) trap when the context has no
  workspace, as the closures trap when not given, so `CommandContext(pane:)` still builds a
  context for the commands that need only a pane. With a workspace, the pane must be the selected
  tab's focused command pane.
- **Close Pane** calls `Workspace.closePane()` and hands the result to `didClosePane`. Dropping
  the pane's view, the tab or the window is the window's job.
- **Zoom.** Split, focus and move end a zoom before they act, even when they then do nothing
  (no neighbor, or a split refused for size). Equalize and close end it in `Layout`, and so does
  resize when it moves a divider. Resize leaves the pane zoomed when no split on the arrow's axis
  holds the pane, since it then changes nothing. Unzoom Pane (Cmd-Opt-Shift-A) only ends a zoom,
  keeps the focus, and is off while the tab isn't zoomed; Zoom Pane stays the toggle.
- **Resize** moves the divider on the focused pane's right edge, or bottom edge for ↑ and ↓,
  by `TilingCommands.resizeStep` (40 pt) the way the arrow points. Only when the pane has no
  divider on that edge does it move the one on its left or top edge. `Layout.resize` picked the
  innermost split on the axis holding the pane, so on the same three columns the middle pane's ←
  moved its right divider in p0 | (p1 | p2) and its left one in (p0 | p1) | p2; it now finds the
  innermost split holding the pane in its first child, then in its second, and the tree's shape
  no longer decides. A split nested inside the moved one keeps its ratio, so its divider shifts
  in proportion, as it does on a divider drag. `DividerAccessibilityElement` uses the same step.
- **Not in the app yet** (superseded: see [0054](0054-tabs-in-window.md)). `TilingCommands` is
  not in `AppCommands.sets`. Every tiling command
  needs the workspace, which the pane's view doesn't pass, so any tiling key would trap in the
  current app, and Cmd-W would stop it at launch. The commands carry their chords from the key
  table, and `AppCommandsTests` registers them beside the app's commands, so a clash fails now.
  M3.5 adds the set to `AppCommands.sets` when its window passes a workspace, bounds and a close
  handler, and replaces Close Window with Close Pane.

## Alternatives considered

- **Register the set now with no chords** — rejected: the key table's chords would wait for
  M3.5 with no clash check, and nothing could run the commands anyway.
- **Pass a workspace from the current window** — rejected for this step: `PaneViewController`
  builds the context and belongs to M2.7, which runs in parallel. Even with one, a split would
  add a pane the window can't show, and Cmd-W would close the only pane with nothing to drop
  the window.
- **Store the selected tab in the context beside the workspace** — rejected: it is the
  workspace's `selectedTab`, and a second copy could disagree with it.
- **Keep `Layout`'s innermost split** — rejected: which divider a key moves would depend on the
  order the splits were made in, which the screen doesn't show.
- **Resize the divider on the edge facing the arrow** — rejected: a pane against the window's
  edge would then have no divider for that arrow.

## Consequences

Until M3.5 the tiling keys beep in the app, as unbound chords with Command do. M3.5 has to add
`TilingCommands` to `AppCommands.sets`, build each context with the workspace, `tabBounds` and
`didClosePane`, and take Cmd-W off the Close Window item.
