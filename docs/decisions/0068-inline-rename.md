# 0068. Inline rename: a field beside the table, cancel on focus loss, New Folder by selection

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M4.7 adds the field Rename opens over the selected row, in the list and in a column
([0066](0066-file-commands.md) left the command and its `editName` hook). The plan says Return
commits through the queue and Esc cancels, but not where the field lives, which part of the name
it selects, what happens when the keys move elsewhere, what the row shows while the rename runs,
or how New Folder knows when to open the field on the folder it made, whose name it learns only
once the operation ends.

## Decision

- **The field sits in the table's clip view**, over the name cell, not in the table. A subview
  of the table would put the table's `runMenuCommand` in the field's responder chain, so
  Cmd-Delete in the field would trash the file being renamed. Beside it, the file commands' menu
  items are off while the field has the keys, as 0066 expects of a text field. The clip view
  scrolls it with the rows.
- **What is selected:** a file's name up to the extension `UniqueName.split` finds, so it splits
  as Finder's copy names do ("song.flac" selects "song", "archive.tar.gz" selects "archive.tar");
  a folder's whole name. `split` is now public for this.
- **Checks:** `FileNameRule` before anything is queued; its reason shows under the field and
  the field stays open. A rename the queue fails, such as onto a taken name, reopens the field
  with the typed name and the reason. An unchanged name closes the field with nothing queued.
- **While the rename runs** the field stays over the old row, showing the new name and not
  editable, and the table takes the keys back. It closes once the rows no longer list the old
  name, which is when the monitor's patch brings the new one; `FileCommands.rename` then selects
  it.
- **Keys moving elsewhere** (a click, Tab) close the field with nothing renamed. Finder commits
  then; a commit with no Return could rename a file the user only meant to look at, and a failure
  would have to take the keys back from wherever they went.
- **New Folder** is seen through a `didRunCommand` hook on `ListingTableView`. The list notes the
  folder, its rows and its selection; the next change of the selection either selects one name
  the rows didn't have before, and the field opens on it through the Rename command, so it uses
  the context's queue, or it is the user's and the wait ends.

## Alternatives considered

- **Edit the cell's own text field with `editColumn(_:row:with:select:)`** — rejected: a patch
  refills cells in place and reused cells show other rows, so the text being typed could be
  overwritten; and the cell is in the table's responder chain.
- **Commit when the keys move elsewhere, as Finder does** — rejected for now, as above.
- **Open the field on any single new name selected after a change** — rejected: Duplicate also
  selects a new name, and Finder doesn't rename after Duplicate.
- **Pass the queue to the field when the context is built** — the context's `editName` takes no
  arguments, so the pane's hook reads the queue from its own context when Rename runs.

## Consequences

The field's frame comes from the table's cell geometry (`ListingViewController.nameFrame`), so a
change to the name cell's layout moves the field with it. Until the window passes a queue
(M4.6), Rename and New Folder are off in the app and the field can't be reached; the tests run
the commands with a queue of their own. If the old row vanishes while the rename runs, the field
closes and a failure then isn't shown in the field; the operations panel shows it.
