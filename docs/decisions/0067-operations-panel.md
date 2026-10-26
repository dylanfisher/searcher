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
  Amended 2026-10-23 to match Finder: Keep Both, Stop, Skip, Replace in one row, Return on
  Replace, Esc on Stop, "Apply to All" ([0076](0076-dialogs.md)).
- **Confirm sheet.** Return confirms, Esc cancels. Delete immediately says "Delete immediately?
  This can't be undone." and marks its button destructive.
- **Both sheets are made through `Dialog`**, the confirm as an `NSAlert` and the conflict as a
  `Dialog.rowSheet`; their hand-built panels were replaced on 2026-10-23
  ([0076](0076-dialogs.md)).
- **The panel** sits under the panes of every window and lists every operation, from snapshots
  only; its buttons send pause, resume and cancel to the queue by ID. A finished operation leaves
  it, except one that failed, was refused or left part of an item behind: that row shows the
  error with its full path until the user clears it.
- **Failed rows belong to the app.** `WorkspaceWindows` keeps the uncleared ones, so a window
  that opens later lists them with the unfinished operations, and a failure reported while no
  window was open shows in the next one. Clearing a row in one window clears it in every window.
- **Showing itself.** The panel shows when an operation is still unfinished 1 s after the panel
  first saw it, or finishes in trouble, and only in the most recently active window. A shorter
  operation that succeeds never shows it.
- **Asking once.** Each operation asks to be shown at most once while it runs, by the 1 s wait
  or the early estimate below, whichever comes first; the other is dropped. A panel the user
  closes stays closed while that operation runs, as Finder's closed copy window stays closed. A
  new operation, or one finishing in trouble, still asks. Until 2026-10-23 the wait started over
  after it fired, so a closed panel came back every second.
- **Showing early for a long copy** (2026-10-23, M4.23). A copy to a share showed the panel only
  after the 1 s wait. Now a running copy with a total is sampled on its first tick, and on each
  later tick the bytes left are divided by the rate since that sample; when that leaves 2 s or
  more (`longEstimate`), the panel shows then, on the tick after the first sampled one, about
  100 ms (one snapshot interval) after that sample rather than after the operation started; a
  pre-scan comes first. Paused, stalled or not yet running, sampling starts over. The rule uses the rate, not the size or the volume
  kind: a same-volume copy of 6 GB is an APFS clone that ends in one tick, and a copy to a fast
  share can be quicker than one to a slow USB disk. 2 s rather than 1 s because the first tick's
  rate can be off by half, as a network write fills its buffers; at 2 s a copy estimated long
  still runs about 1 s after the panel shows, so it doesn't flicker. A copy estimated shorter,
  and anything without bytes to count (trash, rename, a pre-scan still running), waits the 1 s
  as before.
- **Hiding when empty.** `Settings.hideEmptyOperationsPanel`, on by default, as Finder shows
  no panel while idle: a panel that showed itself hides when its last row leaves, cleared or
  finished, and shows again by the rule above. A panel the user opened with Operations stays,
  empty or not, until the user closes it, so a copy ending in another window never closes it.
  Turning the setting on while an empty panel that showed itself is up hides it. Off, the empty
  panel stays and says "No operations".
- **Insets.** Each row sits 9 pt from the panel's sides, `BarInset.horizontal`, shared with the
  path bar so its first folder lines up with the rows' text, and 9 pt above and below (12 and 6
  until 2026-10-23, when Dylan asked for less across and more up and down). Rows sit
  `OperationsViewController.rowGap` (12 pt) apart beyond those insets, and the first has
  `firstRowTopInset` (10 pt) more above it, so a queue of copies doesn't look squeezed together
  (2026-10-25).
- **Size.** The panel is as tall as its rows, up to 200 pt (about three rows), past which they
  scroll; with no rows it is one line saying so. Its height comes from the rows' constraints, so
  it grows and shrinks a row at a time and the panes give up only that room. A progress tick
  changes a row's text and bar, never its height, so it lays out nothing above the row. Each
  row's bar takes the row's width beside its buttons.
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
- **A fixed-height panel** — rejected: one row sat in a box three rows tall.
- **Hiding the empty panel always** — rejected: a user who wants to watch the panel, empty or
  not, can turn the setting off.
- **Hiding every empty panel** — rejected: every window gets every snapshot, so a copy ending
  in one window would close a panel the user opened in another.
- **Show at once for a big total or a network volume** — rejected: the snapshots carry neither
  rate nor volume kind, a big same-volume copy is a clone that ends at once, and a fast share
  copies a few hundred MB in under a second.
- **Failed rows kept per window** — rejected: a window opened later wouldn't list a failure,
  and one reported with no window open would be lost.

## Consequences

The prompter remembers every finished operation's ID for the app's lifetime, one integer each.
A question shows on whichever window was last active, which may not be the one whose key asked
if the user switched windows in between. If the window holding a sheet closes, its question
goes back to the front of the line and shows on the next most recently active window. When
every window is closed while a question is waiting, its operation stays waiting until a window
opens, and the sheet then shows there. A window that opens while operations run lists the
unfinished ones from the last snapshot and the uncleared failures, and shows its panel when
there are failures.
