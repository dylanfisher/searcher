# 0068. Inline rename: a field beside the table, commit on focus loss, New Folder after select

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
  scrolls it with the rows. It has a thin plain border and no focus ring, so it shows at once as
  Finder's does (amended 2026-10-23, [0076](0076-dialogs.md)).
- **What is selected:** a file's name up to the extension `UniqueName.split` finds, so it splits
  as Finder's copy names do ("song.flac" selects "song", "archive.tar.gz" selects "archive.tar");
  a folder's whole name. `split` is now public for this.
- **Checks:** `FileNameRule` before anything is queued; its reason shows under the field and
  the field stays open. A rename the queue fails, such as onto a taken name, reopens the field
  with the typed name and the reason. An unchanged name closes the field with nothing queued.
- **While the rename runs** the field stays over the old row, showing the new name and not
  editable, and the table takes the keys back. It closes once the rows no longer list the old
  name, which is when the monitor's patch brings the new one; `FileCommands.rename` then selects
  it. If the old name is still listed 2 s after the rename is done, the pane lists the folder
  again and the field closes when that listing lands, or after another 2 s. Return in these
  states does nothing: the row still shows a name that no longer exists.
- **Keys moving elsewhere** (a click, Tab) rename as Return does, as Finder does; Esc still
  closes the field with nothing renamed (amended 2026-10-23, at Dylan's ask to match Finder). The
  keys stay where they went while the rename runs. An unchanged name closes the field. As in
  Finder, an emptied name puts the old one back. A name `FileNameRule` refuses, and a rename the
  queue fails, take the keys back to the field with the reason under it: Finder shows the reason
  in an alert and, once it is dismissed, edits the name again, so both end with the user editing
  the name they typed. The field shows it inline, as on Return, rather than in an alert.
  - **Re-entrancy:** Return, Esc and closing the field each move the keys themselves after
    leaving the editing state, so the end of editing that causes is ignored. A focus-loss commit
    doesn't move the keys back to the table, since the window is in the middle of handing them
    to the view clicked; taking them back for a refused name waits a turn of the main actor for
    the same reason, as a first responder set mid-hand-off is replaced by the view clicked.
  - **A click that also changes folder** closes the field before the rename starts; the rename is
    then dropped rather than run in the new folder, since `FileCommands.rename` names the entry
    in the pane's folder.
- **New Folder** edits the new folder's name through the context's `editName`, once the pane
  selects it. `Pane.select(_:whenListedAtSelectionVersion:then:)` runs the closure only when it
  selects the names, so a New Folder that makes nothing, or whose names the user's selection
  overrides, opens nothing.

## Alternatives considered

- **Edit the cell's own text field with `editColumn(_:row:with:select:)`** — rejected: a patch
  refills cells in place and reused cells show other rows, so the text being typed could be
  overwritten; and the cell is in the table's responder chain.
- **Close the field with nothing renamed when the keys move elsewhere** — the first choice,
  since a commit with no Return could rename a file the user only meant to look at. Replaced by
  Finder's behavior on 2026-10-23.
- **An alert for a refused name on focus loss, as Finder shows** — rejected: the reason already
  shows under the field, and an alert would be a second way to say the same thing.
- **Open the field on any single new name selected after a change** — rejected: Duplicate also
  selects a new name, and Finder doesn't rename after Duplicate.
- **Watch the selection in Interface after New Folder runs** — rejected: Interface can't see the
  operation end, so a New Folder that failed left a watch that opened the field on a file another
  app made later.
- **Pass the queue to the field when the context is built** — the context's `editName` takes no
  arguments, so the pane's hook reads the queue from its own context when Rename runs.

## Consequences

The field's frame comes from the table's cell geometry (`ListingViewController.nameFrame`), so a
change to the name cell's layout moves the field with it. The window passes the app's queue
([0067](0067-operations-panel.md)); a pane without one has Rename and New Folder off, so the
field can't be reached, and the tests run the commands with a queue of their own. If the old
row vanishes while the rename runs, the field closes and a failure then isn't shown in the
field; the operations panel shows it. On a volume that reports no changes the field shows the
new name over the old row for up to 4 s.
