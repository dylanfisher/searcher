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
  adds per pane the selection by name, the cursor, the sort column and direction. Not kept: the
  scroll offset, the filter, hidden files (a setting, not per pane), the rows and the selection
  history (record 0077). `SessionState`: the open workspaces' IDs, front window first, and
  the key window's.
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
  deleted and reported too. The other files still load.
- **Writes.** A save is written one second after the first unwritten one
  (`WorkspaceStore.writeDelay`), so the saves in between go out in the same write, one per
  file, through `AtomicWrite` on the store's actor. A write interrupted before the rename leaves
  the previous file. `flush()` writes at once, for quitting. A load sees saves not yet written.
  The store's file calls trap on the main thread (`dispatchPrecondition`). The clock is injected.
- **Problems.** `StoreProblem` names the file, the kind (unreadable, discarded, undeletable,
  unwritten) and the error, and its description is the sentence to show. The store reports each
  one through the `report` closure it is given, from loads and from background writes alike.
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
which M5a.2 does. A `.DS_Store` or other stray file in the workspaces folder is deleted and
reported at the next load. A file written by hand with a lowercase UUID or another number
format doesn't re-encode to itself and is discarded. Nothing deletes a closed unnamed
workspace's file yet; M5a.4 adds that.
