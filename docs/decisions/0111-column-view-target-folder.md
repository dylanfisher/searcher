# 0111. Column view: New Folder and Paste act in the folder selected in the focused column

- **Date:** 2026-10-26
- **Status:** accepted

## Context

Dylan, 2026-10-26: "in column mode, the actions i apply when i have a directory highlighted should
apply to that directory without having to press right arrow to go into the other pane. e.g. i
copy DSC03043.ARW then press or navigate to _test and the file should paste into _test, not into
2026-10-25_rainier-pacmed-walk", and "creating a new folder should automatically highlight the
new folder name to get ready to name it".

Paste, Move Items Here and New Folder put what they make in the context pane's folder, the
focused column's in column view ([0066](0066-file-commands.md), [0069](0069-cut-and-paste.md)).
With a folder selected there, its contents show in the next column, and Finder's column view
treats that folder as the one the window is in: its Paste and New Folder act there.

New Folder was meant to open the name field ([0068](0068-inline-rename.md)), and does in the list.
In a column the field opened and closed in the same turn: `PaneViewController.showViewMode`
counts any text view in the columns as a table with the keys, for the preview's selectable text
([0090](0090-preview-column.md)), and hands the keys back to the focused table on every change
of the pane. New Folder opens the field from inside the change that lists the folder, so the
report of that same change took the keys back, and the field committed the unchanged name and
closed. Any later change, such as a patch or a column opening, closed a Rename field the same
way. The volume doesn't matter: a share's slower listing only delays the same change.

## Decision

- **The destination.** `FileCommands.destination(in:)`: in column view, when the focused
  column has exactly one row selected, that row is a folder, and the column right of it shows
  that folder, New Folder, Paste and Move Items Here act in that column's folder. Otherwise they
  act in the focused column's folder as before: several rows, none, a file, a link (its
  column needs a read to tell) and a package, a file here ([0093](0093-packages-are-files.md)),
  even when Show Package Contents opened its column. List view is unchanged.
- **A selection waiting for the keys to pause** ([0094](0094-column-open-delay.md)) opens its
  column at once when one of these commands runs (`ColumnTrail.selectedFolderColumn(of:)`), as
  → and Open do, so ⌘V right after ↓ onto a folder pastes into it.
- **Fixed when the command runs.** The folder's path goes into the queued operation
  ([0065](0065-operation-queue.md)); a later selection doesn't move it. Undo New Folder, Undo
  Copy and an undone move act on the paths in the operation's record
  ([0072](0072-undo.md)), so they find the items in the selected folder too.
- **What is selected and where the keys go.** What was made is selected in the destination
  column's pane through `Pane.select(_:whenListedAtSelectionVersion:then:)`, read from that
  pane when the command runs. Once it is selected, that column takes the keys
  (`ColumnTrail.focus`), as Finder moves into the folder it pasted into, and New Folder then
  opens the name field there through the context's `editName`, which edits the focused
  column's selection. If the user changes that column's selection first, or selects something
  else in the focused column, which closes the destination column, nothing is selected, the
  keys stay, and no field opens.
- **The name field keeps the keys.** `showViewMode` doesn't move the keys while the focused
  column's rename field is editing. A column that closed with the field in it still hands the
  keys to the focused table.
- **Unchanged:** the commands that act on the selection itself (Copy, Cut, Move to Trash,
  Rename, Duplicate, Get Info, Copy and Move to Other Pane) and drops. A drop names its own
  target, the folder row under the pointer or the column it lands in, as in Finder.
- **The folder menu.** A right-click below a column's rows clears that column's selection, as
  a click there does, so the folder menu's New Folder and Paste act on that column's folder,
  the one the menu is for. The list keeps its selection, as before.

## Alternatives considered

- **Act in the selected folder only once → moved into it** — what the code did, and what Dylan
  reported as wrong.
- **Ignore a selection still waiting for the keys to pause** — rejected: the folder is selected
  and highlighted, so a paste 100 ms after ↓ would go somewhere the user isn't looking.
- **Keep the keys in the focused column after a paste** — rejected: Finder selects the pasted
  items and moves into their column, and New Folder's field has to be in the column the keys are
  in.
- **Keep the column's selection on a right-click below the rows and pass the clicked folder to
  the menu's commands** — rejected: a second way into the commands for one menu, and a column
  with a folder selected and a menu for its own folder would show two folders as the target.

## Consequences

The first Paste or New Folder on a folder selected by keys opens its column at once, a load the
open delay would otherwise have started 120 ms later. A right-click below a column's rows closes
the columns right of it.
