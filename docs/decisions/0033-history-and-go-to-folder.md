# 0033. History and Go to folder: every navigation is a step, and Go to folder moves on its first rows

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M1.5 adds Back and Forward (Cmd-[ and Cmd-]) with a history per pane, and Go to folder
(Cmd-Shift-G), a path field whose missing folder "shows an error and the pane stays"
(`tmp/behavior.md`). Stepping back selects the entry that was selected when the pane left the
folder. Whether a typed folder exists is a file-system call, which can't run on the main thread,
and the menu items for Back and Forward have to disable at the ends of the history.
`CommandBinding` had no way to say a command can't run, and `CommandContext` gave a command only
the pane, which can't show a sheet: Browser has no AppKit.

## Decision

- **What is a step.** `Pane.navigate` records the folder it leaves, so Open (Cmd-↓, Cmd-O, a
  double-click), Go to parent (Cmd-↑), a path bar click and Go to folder are all steps, as in
  Finder. Going to the folder the pane is in, by either, isn't one: it lists the folder again
  as a reload, keeping its folder monitor, which `PaneViewController` restarts only when the
  location changes. Back and Forward move without recording. `History` keeps two stacks of a
  location and the name under the cursor there, nothing else: no filter, no sort, no scroll
  position. It has no size limit.
- **Restoring the selection.** Back and Forward move as a navigation with a name to select does,
  by `ExactName`, so the selection is resolved on the load's worker and goes through the
  provisional and settled paths of [0029](0029-row-movement.md) if the user moves first. A
  folder gone since fails to list and shows the failed state, like any navigation; it isn't
  skipped or removed from the history.
- **Disabled at the ends.** `CommandBinding.isEnabled`, beside `isChecked`, says whether a
  command would do something. `ListingTableView` validates the items it runs with it through the
  pane's view controller. A key that reaches `keyDown` with its item disabled runs the command,
  which does nothing.
- **Go to folder checks by listing.** `PathInput` expands `~`, `~/…` and paths relative to the
  pane's folder, and takes `.` and `..` apart by their text, with no file-system call.
  `Pane.goToFolder` then asks `ListingService` for a load of the target, so the check is the
  listing itself, off the main thread. The pane stays where it is, with its rows, selection and
  monitor, until the first update. Rows (a first batch or the full listing) move the pane, and
  the load becomes the pane's own. Not found and not a folder report the error and leave the pane
  untouched, with no history step. Privacy protection and other failures move the pane into the
  denied or failed state, as navigating there would, so the user sees how to grant access.
- **The sheet.** `CommandContext` carries `askForFolder`, which `PaneViewController` sets to show
  `GoToFolderSheet` over the pane's window. The sheet stays up while the folder lists, shows "There’s
  no folder at “path”." (or "isn’t a folder") under the field, and closes when the pane moves.
  Esc cancels the pending load. Its field editor keeps the text-editing keys
  ([0027](0027-key-dispatch.md)).

## Alternatives considered

- **Check the path with `stat` before navigating** — rejected: a second file-system call per go,
  which would still need a worker thread, and the folder can go between the check and the list.
- **Navigate at once and go back on not found** — rejected: the pane would show the spinner and
  drop its rows and monitor for a folder that isn't there, and the history would gain and lose a
  step.
- **Stay on every failure** — rejected: a folder behind privacy protection exists, and the denied
  state is where the app explains how to grant access.
- **Only Open and Go to folder push history, not Go to parent** — rejected: Finder records Cmd-↑,
  and Back after Cmd-↑ is how a user returns to the child.
- **Show the sheet from a `Pane` callback** — rejected: asking the user is the view's job; the
  command context already says what a command acts on.
- **Expand `~user`** — not yet: it needs a directory-service lookup. `~notes` is a name.

## Consequences

A slow folder typed in Go to folder keeps the sheet up until its first rows arrive; Esc gives up.
The history grows without bound for a pane's life, a few hundred bytes a step. A path with a
symbolic link and `..` is taken apart by its text, so `link/..` is the folder holding the link,
not the link target's parent, as in Terminal's `cd` rather than `cd -P`. `CommandContext(pane:)`
without `askForFolder` traps if Go to folder runs on it; the UI bench and tests build it that
way for other commands.
