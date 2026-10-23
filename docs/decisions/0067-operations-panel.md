# 0067. Operations panel: one app queue, one sheet at a time on the front window

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M4.5 made the file commands, which stay off until a window passes a `FileOperationQueue`
([0066](0066-file-commands.md)). The queue asks its questions through `Prompts` and shows its
progress through snapshots ([0065](0065-operation-queue.md)); something has to answer the one and
draw the other. The questions carry no window: a `ConflictRequest` names an operation, the
other-pane confirm names nothing, and two Cmd-Shift-C presses ask two questions at once.
`tmp/behavior.md` gives no key for the panel.

## Decision

- **One queue for the app.** `WorkspaceWindows` makes it with an `OperationPrompter`'s prompts and
  passes it to every window, which puts it in each pane's `CommandContext`. Copies from any
  window share the volume lanes, and a rename in one window is refused while a copy in another
  reads the item.
- **One sheet at a time.** The prompter keeps the questions in the order asked and shows the
  first as a sheet on the most recently active window (`WorkspaceList.workspaces.first`). The
  next shows when it is answered. With no window open a question waits, and the next window to
  open shows it. Each question is an awaited call, never a modal loop, so other windows keep
  their keys while a sheet is up.
- **Closing questions.** A snapshot that shows an operation finished closes its question, shown
  or waiting, and a question asked about an operation already seen finished returns at once. The
  queue drops what either returns. Cancel on the conflict sheet cancels the operation through the
  queue and returns only once the queue has finished it, so the answer is dropped.
- **Conflict sheet.** Replace, Skip and Keep Both, with Return on Keep Both, since it loses
  nothing; Esc cancels. "Do the same for N more conflicts" shows only when more follow.
- **Confirm sheet.** Return confirms, Esc cancels. Delete immediately says "Delete immediately?
  This can't be undone." and marks its button destructive.
- **The panel** sits under the panes of every window and lists every operation, from snapshots
  only; its buttons send pause, resume and cancel to the queue by ID. A finished operation leaves
  it, except one that failed, was refused or left part of an item behind: that row shows the
  error with its full path until the user clears it.
- **Showing itself.** The panel shows when an operation is still unfinished 1 s after the panel
  first saw it, or finishes in trouble, and only in the most recently active window. A shorter
  operation that succeeds never shows it.
- **Key.** Operations, Cmd-Opt-L, in the Window menu after the window moves. The key table has
  none; Cmd-Opt-L is Safari's Downloads key and no command or standard item used it. It works
  from the filter field too, like the other window commands.

## Alternatives considered

- **A queue per window** — rejected: two windows copying to one disk would fight over it, and a
  rename in one window couldn't be refused while the other copies the item.
- **Sheets on the window whose pane asked** — rejected: `Prompts` carries no window, and the
  front window is the one the key was pressed in for the other-pane confirm.
- **Show every waiting question at once, one sheet per window** — rejected: two confirms from
  one window would stack on it, and which window gets which is arbitrary.
- **App-modal alerts** — rejected: they block every window until answered.
- **One panel for the app, in its own window** — rejected: the plan asks for a panel attached to
  the window, and a floating window would take focus as it opens.
- **Show the panel in every window after 1 s** — rejected: every window would grow a panel for
  one copy.

## Consequences

The prompter remembers every finished operation's ID for the app's lifetime, one integer each.
A question shows on whichever window was last active, which may not be the one whose key asked
if the user switched windows in between. If the window holding a sheet closes, its question
goes back to the front of the line and shows on the next most recently active window. Each
window's panel keeps its own failed rows,
so clearing one in one window leaves it in another. A window that opens while operations run
lists the unfinished ones from the last snapshot.
