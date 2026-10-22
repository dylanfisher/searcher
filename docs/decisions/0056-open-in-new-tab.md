# 0056. Open in New Tab: one command, with the clicked folder in the context

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.6a adds the two clicks `tmp/behavior.md` gives for a new tab at a folder: Cmd-double-click on
a folder row and Cmd-click on a path bar segment. A Cmd-click on a row stays toggle-select, and a
Cmd-double-click on a file opens it. Commands get what they act on from `CommandContext`
([0010](0010-command-registry.md)), which holds no folder: a key or menu item acts on the
selection. The path bar's folder is an ancestor of the pane's, so it can't be selected. New Tab
and Split each built the new pane by hand, copying the view mode, sort and folder sizes
([0054](0054-tabs-in-window.md)); this command is the third copy.

## Decision

- **`Pane.newPane(at:)`** makes a pane at a folder in this pane's view mode, sorted as its
  focused column is, with its folder sizes, services, settings and system actions. `Tab.split`,
  New Tab and Open in New Tab all call it, so a new tab from a folder takes the source pane's
  view mode, as a split and Cmd-T do.
- **`WindowCommands.openInNewTab`** ("Open in New Tab") adds a selected tab at
  `CommandContext.folder`, made from the selected tab's focused pane. It has no chord and no menu
  item, and is off without a folder; run without one, it traps. Keys and menu items leave
  `folder` nil.
- **One route in Interface.** `PaneViewController.openInNewTab` runs the command with the
  folder. The table's `openInNewTab` and the path bar's `onOpenInNewTab` both call it.
- **Focus.** A path bar button takes no keys, so a Cmd-click can come from a pane that isn't
  focused. `openInNewTab` focuses that pane through `Tab.focus` first, since the context must be
  built on the focused pane, and the new tab is made from the pane that was clicked. After the
  command the window selects the new tab and moves the first responder into it, as after any
  command, so model focus and first responder stay in step.
- **Rows.** On a double-click with Command held, a directory row runs Open in New Tab with its
  folder. Any other row, a symbolic link included, runs Open as a plain double-click does. Either
  way the clicked row ends up selected: the two clicks' Cmd-click toggles have run before the
  double-click action, and a row they left out is selected again.
- **Column view** gets it with no extra code: each column is a `ListingViewController` whose
  table the pane prepares like the list's. The new tab opens at the clicked column's folder in
  column view.
- **Path bar.** A Cmd-click on any segment opens it, the pane's own folder included, where a
  plain click does nothing.

## Alternatives considered

- **A command that opens the selection in a new tab** — rejected: the path bar's folder can't be
  selected, so the path bar would need a second route.
- **A second callback from the path bar that adds the tab itself** — rejected: two code paths for
  one action, and the step asks for one command.
- **Open a symbolic link to a folder in a new tab** — not done: telling a link to a folder from
  one to a file takes a file-system call. Open already resolves links; a link opens in the same
  pane.
- **Give the command a chord or menu item** — not done: `tmp/behavior.md` gives it neither, and
  with no folder it does nothing.

## Consequences

A Cmd-click in another pane's path bar moves the focus in the source tab to that pane, so going
back to that tab shows it focused. `CommandContext` carries one optional field that only this
command reads.
