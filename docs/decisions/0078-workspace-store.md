# 0078. Workspace store: one JSON file per workspace, a session file, one shape

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M5a restores every window at launch and keeps named workspaces. Workspaces can't be rebuilt, so
they live under the application support root (`StoreRoots`), not the caches root the listing
cache uses ([0039](0039-listing-cache.md)). Every workspace change is saved (M5a.2), so a drag of
a divider or a run of arrow keys must not write a file each time. A crash mid-write must not
cost the workspace. The project is pre-release: stored data has one shape, with no version
field, and a file of any other shape is discarded. A file that is discarded or can't be written
is shown to the user, not only logged. B1 is timed from a cold launch to every restored window
on screen, with frames and tab strips set and the key window's focused pane showing rows.

## Decision

- **Files.** `<application support root>/workspaces/<id>.json` per workspace, named by its
  `WorkspaceState.id` (a UUID, so a rename keeps the file), and
  `<application support root>/session.json` beside the folder, so the folder holds only
  workspace files. JSON, with sorted keys, so the same state writes the same bytes.
- **What is kept.** `WorkspaceState`: ID, name (absent when unnamed), window frame as `Rect`,
  the tabs as `TabState`, the selected tab's index and whether the sidebar shows. `TabState`
  adds per pane the selection by name, the cursor, the sort column and direction (amended
  2026-10-26: the list's sort, also in column mode; a column's sort isn't kept, and restored
  columns open by Name ascending, see [0041](0041-column-model.md)). Not kept: the
  scroll offset, the filter, hidden files (a setting, not per pane), the rows and the selection
  history ([0077](0077-selection-history.md)). `SessionState`: the open workspaces' IDs, front
  window first, and the key window's.
- **Selection by name.** `Tab.state` takes a settled selection of names as it is, so a pane
  still loading keeps the names it will select. Any other selection, such as Select All's
  "every row but these", is stored as the selected rows' names: a restored Select All then
  selects what was there, not entries added since.
- **One shape.** A file is read only if it decodes and re-encodes to the same JSON value; else
  it is deleted and reported. Decoding alone ignores keys a type doesn't declare, and the
  comparison catches one anywhere in the file, including in `Layout`, without a key check in
  each type. The decoders reject what breaks an invariant: a selected tab out of range, panes
  that don't match the layout's leaves, a key window not in the session, a workspace listed
  twice. A workspace file not named `<its id>.json`, and any other file in the folder, is
  deleted and reported too. The other files still load. (Amended 2026-10-25: a pane's column
  widths of another shape are dropped alone and the file loads, is written back without them
  and is reported as `widthsDropped`; the decoder records the path in the file of each
  pane whose widths it dropped, and the comparison leaves out exactly those panes'
  `columnWidths` keys and nothing else, so any other difference, a `columnWidths` key or a
  `null` anywhere else among them, still discards the file. A file the load deletes for another
  reason isn't written back first. See
  [0098](0098-column-widths-per-window.md).)
- **Leftovers and dot-files.** A crash between `AtomicWrite`'s write and rename leaves its
  temporary file in the workspaces folder; the load deletes it without a report, since the file
  it was to replace is still there. `AtomicWrite.isPartial` is the one test of that name. Any
  other dot-file, such as Finder's `.DS_Store`, is left alone and not reported.
- **A session naming a missing workspace.** `load()` returns the session as saved. A workspace
  whose file is missing or was discarded is absent from `workspaces`; a discard was reported
  already. M5a.2 skips each ID with no workspace, and the next session it saves drops it.
- **Writes.** A save is written one second after the first unwritten one
  (`WorkspaceStore.writeDelay`), so the saves in between go out in the same write, one per
  file, through `AtomicWrite` on the store's actor. A write interrupted before the rename leaves
  the previous file. `flush()` writes at once, for quitting, and cancels the pending wait, so a
  save after it waits the whole delay. A load sees saves not yet written.
  The store's file calls trap on the main thread (`dispatchPrecondition`). The clock is injected.
- **Problems.** `StoreProblem` names the file, the kind (unreadable, discarded, undeletable,
  unwritten; widthsDropped since 0098) and the error, and its description is the sentence to
  show. The store reports each one through the `report` closure it is given, from loads and
  from background writes alike.
- **Where B1 ends.** The store's read is inside B1: M5a.2 reads the session and its workspaces
  off the main actor before the first window, and B1 ends when every restored window is on
  screen with its frame and tab strip and the key window's focused pane shows rows.

## Alternatives considered

- **One file for every workspace** — rejected: one damaged byte would discard every workspace,
  and each edit would rewrite all of them.
- **A key check in each stored type, as the listing cache does** — rejected: `Layout`,
  `LayoutNode` and `TabState` use decoding that ignores extra keys, and each would need its own
  coding. Files are a few kilobytes, so decoding twice costs nothing measurable.
- **Write on every save** — rejected: a resize or a run of selection changes would write the
  file per event.
- **Return problems from `load()`** — rejected: background writes have no caller to return to,
  and two channels for the same thing would differ.
- **Keep the scroll offset** — rejected by the plan: restoring the selection scrolls to it.

## Consequences

A save in the second before the app is killed is lost unless the app calls `flush()` on quit,
which M5a.2 does. A stray file in the workspaces folder that isn't a dot-file is deleted and
reported at the next load. Only the workspaces folder is cleaned of leftovers: one of
`session.json`'s, in the application support root, stays until something else cleans that
folder. A file written by hand with a lowercase UUID or another number
format doesn't re-encode to itself and is discarded. A closed unnamed workspace's file is
deleted ([0082](0082-saved-workspaces.md)).

## Amendment: snapshots (2026-10-24)

Saved workspaces now keep a snapshot apart from their window, one JSON file each in
`<application support root>/snapshots/<id>.json`, read and checked as the workspace files are; one
without a name is deleted and reported. `workspaces/` holds the open windows only, and a window's
file is deleted when it closes. See [0088](0088-workspace-snapshots.md).

## Amendment: failed writes, durable renames, absolute paths (2026-10-27)

A persistence audit (2026-10-27) found three gaps; the owner's rule is that persistence has no
edge cases.

- **A failed write stays pending.** `flush()` drops a save from the pending ones only once its
  write succeeds. A write that fails, or a flush whose folders can't be made, is reported as
  `unwritten` and kept, and the flush schedules another write `writeDelay` later, so it is
  retried every second until it succeeds or a newer save or a delete replaces it. Before, the
  save was dropped before its write, so a full disk lost the change while `WorkspaceWindows`
  took it as saved. The flush runs on the store's actor with no suspension, so no save can land
  between the write and the drop. A file's `unwritten` problem is reported once, then not again
  until a write of that file succeeds or the file is deleted: every problem shows in an alert
  ([0080](0080-restore-at-launch.md)), and a full disk would otherwise raise one per retry.
  - **Alternatives considered.** Retry only at the next save or at quit — rejected: with no
    further change, a crash or a forced quit loses the write, an edge case the timer doesn't
    have. The timer costs one failed write a second, off the main thread, while the disk stays
    full.
- **`AtomicWrite` syncs before the rename.** The temporary file is `fsync`ed, through its file
  handle, before it is renamed over the old one, so a power loss after the rename can't leave an
  empty file where the workspace was. `F_FULLFSYNC`, which also empties the drive's own cache,
  was rejected for its cost on every write. The folder isn't synced after the rename either: a
  power loss can then undo the rename, which leaves the previous file whole, so at most the last
  write is lost, as with any crash before a write; syncing the folder would add a second sync to
  every write to save that one write. No timed bench writes through `AtomicWrite`: the
  `restored-session` scenario writes its fixture with `Data.write`, and the listing cache's
  writes are untimed, after its delay and off the main thread. At quit the sync is inside the
  shared 2 s deadline; the files are a few kilobytes.
- **Stored paths are absolute.** A location stored as a path, the pane's, a history entry's or a
  column width's, that is empty or doesn't start with `/` fails to decode, which discards the
  workspace and reports it, as `FolderHistory` rejects such a path.
- **An undated window file is reported.** A session rebuilt from the window files
  ([0080](0080-restore-at-launch.md)) orders them by modification date. A file whose date can't
  be read is reported as `undated` and ordered behind the others; its window is still restored.
