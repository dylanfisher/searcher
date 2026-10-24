# 0082. Saved workspaces: a name makes one, closing keeps it, delete asks

- **Date:** 2026-10-24
- **Status:** accepted; the autosave of a named workspace, the state kept at close and Name
  Workspace… are superseded by [0088](0088-workspace-snapshots.md)
- **2026-10-24:** a saved workspace is now a snapshot that only Save Workspace changes; see
  [0088](0088-workspace-snapshots.md).

## Context

M5a.4 makes a named workspace a saved one: it autosaves like every workspace
([0080](0080-restore-at-launch.md)), closing its window keeps it, and opening it brings its window
back as it was at close, or focuses the window if it is open. There is no explicit Save, no
template mode and no separate saved-item type. Every workspace already has a file
([0078](0078-workspace-store.md)), and nothing deleted an unnamed one's file once its window
closed. The palette (M5a.6) and the sidebar (M5a.8) will list and open saved workspaces; this
step adds the model, the files and the commands on the window's own workspace.

## Decision

- **`WorkspaceList` holds saved and open.** Besides the open workspaces it keeps `closed`, the
  saved workspaces whose windows are closed, each as the `WorkspaceState` it had at close.
  `saved` lists every named one, open or closed, in Finder's name order
  (`localizedStandardCompare`), with whether it is open.
- **Names are unique.** `WorkspaceList.name(_:as:)` trims white space and refuses an empty name
  or one another saved workspace has, compared without case as an APFS volume compares file
  names. The refusal names the existing workspace as it is spelled there, in Finder's words for
  a taken file name: "The name “Project 1” is already taken. Please choose a different name." A
  workspace may change the case of its own name.
- **Every window close goes through `windowClosed(_:as:)`.** A named workspace moves to `closed`
  with its state at close; an unnamed one is forgotten (`onForget`), and `WorkspaceWindows` has
  its file deleted with the next save. A workspace whose tabs were merged into another window
  is decided the same way when its window closes, so a named one stays saved with the tabs it
  had. `BrowserWindowController` now tells its owner of the close before closing the tabs, so
  the state at close can be read; a change made within the save delay before the close is kept.
  When Close Pane on the last pane or Close Tab on the last tab closes the window, the state
  kept is the workspace just before that command, with the closed tab's folders and
  selections, as Finder keeps a window as it was: `Workspace` takes its tabs' states before it
  closes the last one (`tabStates`).
- **Open.** `WorkspaceList.open` activates an open workspace, or rebuilds a closed one from its
  state; `WorkspaceWindows.open(savedWorkspace:)` then makes the window, at its saved frame moved
  onto a display if needed, or makes the open one's window key. It takes an ID, so it is not a
  registered command; the palette and sidebar call it.
- **Delete** closes the workspace's tabs, drops it from the list, which closes its window, and
  forgets it. The Window menu's Delete Workspace… asks first, as a `Dialog` sheet with a
  destructive Delete ([0076](0076-dialogs.md)), since the layout can't be undone back. It is off
  for an unnamed workspace, which closing its window already forgets, so it is also the step's
  close-and-forget.
- **Name Workspace…** (Rename Workspace… once named) shows a `Dialog` alert sheet with a name
  field, like Go to folder: a refused name shows why under the field and keeps the sheet up, and
  an empty one beeps. Neither command has a chord.
- **Files follow the saving rules of [0080](0080-restore-at-launch.md).** A state at close and a
  file to delete go to the store in the next save, in the same ordered batch as other saves, so
  they wait for the launch's restore, and a state equal to what the store was last given is not
  handed again. `WorkspaceStore.delete` drops an unwritten save of the workspace and deletes its
  file; a missing file is not a problem, and a failure is a `StoreProblem` of kind `unforgotten`.
- **At launch** a named workspace that isn't in the session is listed as closed, and an unnamed
  one, which a crash left, has its file deleted. If `session.json` doesn't decode, no workspace
  is open, so every unnamed file is deleted: none of them could be restored anyway.
- **Names are unique after every launch.** Only a file edited by hand can repeat a name. A
  workspace whose name an earlier one has keeps its layout and gets the next free name, as
  Finder names a duplicate: "Project 1 2", then "Project 1 3", compared with the same folding
  as naming (`WorkspaceList.freeName`). The renamed file is saved and the rename logged. Open
  windows go first, front to back, then closed workspaces in name and ID order, so the front
  window keeps its name.
- **No naming before the launch's restore.** Until the restore lists the closed saved
  workspaces, their names aren't known, so `WorkspaceList.name` refuses with "Saved workspaces
  are still loading. Try again in a moment.", which the name sheet shows. The wait is the
  store's read, a few milliseconds.

## Alternatives considered

- **Delete a workspace whose name is taken at launch** — rejected: it loses the user's layout
  for a clash the user can fix by renaming.
- **Forget a named workspace when Merge Window into Tab takes its tabs** — rejected: merging
  closes its window, and closing a saved workspace's window keeps it everywhere else.
- **Delete without asking** — rejected: Delete closes the window and loses the layout, and the
  undo history holds file operations only.
- **Show the name in the window title** — not done: the title follows Finder's folder title, and
  the sidebar (M5a.8) shows names.
- **Delete unnamed files at once on close** — rejected: deletes would bypass the save batches,
  so a delete could run before an older save of the same file, and before the launch's restore.

## Consequences

A saved workspace can be reopened only through `WorkspaceWindows.open(savedWorkspace:)` until
the palette and sidebar land. A window opened by New Window while the launch is still reading
the store can't be named until the restore has run. A file edited by hand to repeat a name
comes back under a numbered name at the next launch, with a log line.

Each save that writes or deletes a workspace gives the listing cache the folders of every
stored workspace (`ListingCache.keep(folders:)`), so a workspace named, or a pane moved, during
the session keeps its folders through the caps from that save on.
