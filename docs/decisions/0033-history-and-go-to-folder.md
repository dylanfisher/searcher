# 0033. History and Go to folder: every navigation is a step, and Go to folder moves on its first rows

- **Date:** 2026-10-22
- **Status:** accepted
- **2026-10-27:** Back and Forward go on to the window's own steps; see
  [0125](0125-workspace-open-is-a-back-step.md).

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
  position. It has no size limit. (Amended 2026-10-25: in column view each move of the keys to
  another column is a step too, since the pane's folder is the focused column's, and Back or
  Forward to a folder the trail shows moves the keys to its column, selecting the remembered
  entry against the rows it already has, instead of listing it again; see
  [0041](0041-column-model.md).) (Amended 2026-10-27: each way keeps its nearest 500 entries
  (`History.limit`) and drops the farthest, since column moves add a step per key and
  `TabState` saves the whole history. A saved history past 500 keeps its nearest 500 rather
  than being discarded: it has the one stored shape, only longer, and the user's recent Back
  steps are worth more than the rule. Finder's own depth is unverified.)
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
  ([0027](0027-key-dispatch.md)). It is a `Dialog` alert with the field as its accessory view
  (amended 2026-10-23, [0076](0076-dialogs.md)).

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
A pane's history is at most 1,000 entries, 500 each way, a few hundred bytes a step. A path with a
symbolic link and `..` is taken apart by its text, so `link/..` is the folder holding the link,
not the link target's parent, as in Terminal's `cd` rather than `cd -P`. `CommandContext(pane:)`
without `askForFolder` traps if Go to folder runs on it; the UI bench and tests build it that
way for other commands.

## Amendment: the window's steps (2026-10-27)

Opening a saved workspace into its window keeps what the window showed as a step of the
window's own Back and Forward ([0125](0125-workspace-open-is-a-back-step.md)). Back runs on the
focused pane while its history has a step, and on the window once it hasn't; Forward is the
same. Each item is on when either can step. Every folder a pane leaves, the `History.leave` of
the Decision, now also ends the window's way forward.
