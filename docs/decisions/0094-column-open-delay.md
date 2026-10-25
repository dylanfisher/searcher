# 0094. Column view opens the next column once the keys pause

- **Date:** 2026-10-24
- **Status:** accepted

## Context

Each selection change in a column ran `ColumnTrail.follow` at once ([0041](0041-column-model.md)).
Holding ↓ through a column of folders made a column controller and a table for every row, started
its load and its folder monitor, and closed the previous column's on the main thread.
[0046](0046-column-view.md) named this the B6 risk, and on a share every row's load joined the
listing queue ahead of the one the user stopped on. Since [0090](0090-preview-column.md) a held key
through files also refilled the preview on every row. Finder moves the selection on every key and
opens the selected folder's column, or shows the file's preview, only once the keys stop.

## Decision

- **Keys wait, clicks don't.** A selection made by a row key (↑, ↓, Shift-arrows, Opt-, Ctrl-Shift-
  and Fn-arrows), by Opt-↑ or Opt-↓, or by type-to-select sets `Pane.selectionIsFromKeys`. The trail
  then drops the columns right of it that the new selection doesn't ask for at once, clears the
  preview if it showed another file, and opens the new column or preview after
  `ColumnTrail.openDelay` with no further selection change in that column. Each new key starts the
  wait again, so only the selection the keys stop on opens anything. A click, a command's selection,
  Select All, Undo Selection and a selection that names rows a load brings follow at once, as
  before. A click on the row the keys selected follows it at once too, even though it changes no
  row.
- **Only the new selection waits.** Once the columns follow a key-made selection, after the pause or
  →, a later change that keeps it, such as a patch that turns the selected entry into a folder, is
  followed at once. `Column.followedSelectionVersion` tells such a change from a new selection.
- **120 ms.** Finder's pause looks like about 100 ms; it hasn't been measured. The delay has to be
  longer than the gap between a held key's repeats, or a held arrow opens a column per repeat: that
  gap is 30 ms at the fastest Key Repeat setting and 90 ms at the next. 120 ms clears both with room
  for event jitter and is still short enough that one press feels immediate. Slower repeat settings
  (180 ms and up) open a column per repeat, as they would in Finder.
- **Stale columns go at once.** Finder appears to empty the columns right of the selection as soon
  as it moves and to show the new one after the pause; showing the old folder's column next to a new
  selection would show the wrong contents. The trail does the same.
- **→ doesn't wait.** → on a folder whose column is still waiting opens it at once and moves into
  it, and → on a file whose preview is waiting shows it. → selects the first row of the column it
  moves into without the key flag, so a folder there opens its column at once too: each → needs the
  column to its right to exist.
- **← gives up the wait.** ← from a column whose selection is waiting cancels the wait; the folder
  selected there opens no column until → or another selection. A later report from that column, such
  as a patch, doesn't start the wait again for the same selection. Closing the pane, going back to
  the list and navigating close every column, which cancels its wait.
- **One wait per column.** `Column.held` keeps the waiting selection's version and its task. The
  wait takes its deadline on `Pane.columnOpenClock` when the selection changes, so tests advance a
  `ManualClock` past it.
- **A column watches its folder from the start.** `ColumnViewController` still starts a column's
  monitor when the column is made, before its listing, so no change between the read and the watch
  is missed. The pause already keeps a held key from making a column, and so a monitor, per row.
- **The path bar and Quick Look are unchanged.** Both follow the focused column and its selection,
  which change at once; neither needs the next column.

## Alternatives considered

- **Delay by key repeats only (`isKeyRepeat`)** — rejected: Finder waits after a single press too,
  and fast separate presses flood the queue as a held key does.
- **Keep the old column until the new one opens** — rejected: for the length of the pause it shows a
  folder that isn't the one selected.
- **Read the delay from `NSEvent.keyRepeatInterval`** — not done: it would tie the Browser tier to
  AppKit for one number, and the fixed value covers the two fastest repeat settings.
- **Start a column's monitor once its first rows land** ([0046](0046-column-view.md)'s suggestion) —
  rejected: a change made between the listing's read and the monitor's start would go unseen until
  the next change or reload, and with the pause a column passed over by a held key is never made, so
  there is no monitor left to save.

## Consequences

The B6 column ↓ case in the UI bench now times the selection's frame with the stale column dropped,
since its presses come faster than the pause, as a held key's do; the column the presses stop on
opens after the pause and is no key's frame. Its cost shows as a stall, if any, in B10. The → and ←
cases are unchanged: the bench waits for the column to open before them.

One press on a folder now shows its column 120 ms later than before.
