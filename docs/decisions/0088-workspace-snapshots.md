# 0088. Workspace snapshots: Save Workspace keeps a state, going back loads it

- **Date:** 2026-10-24
- **Status:** accepted

## Context

[0082](0082-saved-workspaces.md) made a named workspace autosave: every change to its window
went into its one file, and closing the window kept the state just before the last tab or pane
closed. Dylan's feedback (2026-10-24): saving should keep the workspace as it was when saved;
moving around afterwards and then going back to the workspace should load that state, and
changing it means saving again. He also asked for "Save Workspace" in place of "Name Workspace"
and for a Focus Sidebar chord ([0086](0086-workspace-sidebar.md) gave it none). Session restore
([0080](0080-restore-at-launch.md)) still brings every window back as it was at quit.

## Decision

- **Two states per saved workspace.** Its *snapshot* is the `WorkspaceState` it had when last
  saved; its window, while open, has its own state, which autosaves for session restore as every
  window's does. They share the workspace's ID, which is the link between them. The store keeps
  snapshots in `<application support root>/snapshots/<id>.json` and the open windows in
  `workspaces/<id>.json`, as before ([0078](0078-workspace-store.md)). A snapshot without a name
  is a file of another shape: deleted and reported.
- **Only three things write a snapshot.** Save Workspace, Rename Workspace (the name only) and
  the launch's renaming of a clashing name. Navigating, splitting, closing tabs or panes and
  closing the window never do. 0082's "state just before the last close" rule is gone, with
  `Workspace.tabStates`; closing a window deletes its window file, linked or not, and
  `WorkspaceList.windowClosed` takes no state.
- **Save Workspace… (Command-S)** replaces Name Workspace…. On a window not linked to a saved
  workspace it shows the name sheet ("Save this workspace as:", Save), with the same uniqueness
  rules and the same refusal until the launch's restore; on a linked one it overwrites the
  snapshot with the window's current state without asking, as Save does in a document app, and
  its title drops the ellipsis then ("Save Workspace"), as the HIG has it for a command that asks
  nothing. Rename Workspace… is its own command now, on for a saved workspace only. Delete
  Workspace… is unchanged.
- **Going to a saved workspace** (sidebar click or Return, palette item,
  `WorkspaceWindows.open(savedWorkspace:)`): with no window linked it opens one from the
  snapshot, as before; with one linked it brings it forward and, if its state differs from the
  snapshot, shows the snapshot in it. When only the frame differs, the window moves to the
  snapshot's frame and keeps its panes, scroll positions and histories. Otherwise
  `Workspace.reload` closes every tab it had, panes and all, and puts in tabs rebuilt from the
  snapshot, and the window takes the snapshot's frame. The rebuilt panes are new, so their
  selection history starts empty; the undo history holds file operations only
  ([0072](0072-undo.md)) and is untouched. A window as the snapshot has it is left alone. In
  every case the keys go to the window's focused pane, from the sidebar too.
- **A frame shown as saved reads as saved.** A snapshot's frame is moved onto a display, and
  shrunk to fit one, when it is on none ([0080](0080-restore-at-launch.md)), so the window can't
  always be at it. Where showing a snapshot put the window is remembered per window; while the
  window is still there, and while it is in full screen, its frame counts as the snapshot's.
  Without this a window saved on a display since removed would show the edited dot for good and
  reload on every go-to. A save at the window's own frame drops what was remembered.
- **Pane IDs repeat.** A snapshot keeps its panes' IDs, so a pane that moved to another window
  (Move Pane to New Window) can share an ID with a pane the snapshot rebuilds. A window hands a
  pane's view controller over only to that same pane (`handOver(_:of:)`), not to any pane with
  its ID.
- **The edited dot.** A linked window sets `isDocumentEdited`, the dot in its close button, while
  its state differs from its snapshot, compared with `WorkspaceState`'s equality, the one the save
  path uses. The save path sets it when it reads a window's state, `saveDelay` after the changes
  stop, so the dot costs no extra `Tab.state` read; Save Workspace, a rename and a reload set it
  at once. Frame, tabs, layouts, folders, selections, sorts and the sidebar all count, as the
  snapshot keeps them, the frame as the bullet above reads it.
- **Launch.** Session restore is unchanged: each window comes back from its window file, as it
  was at quit. A window is linked when a snapshot with its ID loaded, and takes the snapshot's
  name; one whose snapshot is gone comes back unsaved. The edited dot shows when the restored
  state differs from the snapshot. Free names are given to snapshots, the open windows' first,
  front to back, then the closed ones by name, so the front window keeps its name. Window files
  the session doesn't list are deleted, as crash leftovers.
- **Focus Sidebar (Command-0)** shows the sidebar and moves the keys into it; pressed while the
  sidebar has the keys, it gives them back to the focused pane and leaves the sidebar showing,
  as Esc does.
- **Chords checked.** Neither Command-S nor Command-0 was in the command registry, which refuses
  two commands on a chord (`AppCommands.registry()`), or among the menu's standard items
  (Command-H, Option-Command-H, Command-Q, Command-M and the text-editing chords). Finder's menus
  use neither: Finder has no Save, and its View menu's digits are Command-1 to Command-4.
  Equalize Panes keeps Option-Command-0.

## Alternatives considered

- **Keep one file per workspace and add the snapshot inside it** — rejected: a closed saved
  workspace has a snapshot and no window, an unnamed window a window and no snapshot, so the one
  type would carry an optional half either way.
- **Snapshots in `workspaces/` and windows in a new folder** — rejected: it would keep the saved
  workspaces of the old build, but turn every unnamed window file into a reported discard, and
  pre-release stored data has one shape with no migration.
- **Close the linked window and open a new one from the snapshot** — rejected: the window would
  flash closed and open and lose its place in the window order; reloading in place keeps the
  window and changes only what the snapshot holds.
- **Compare states on every change for the dot** — rejected for the reason saves wait
  ([0080](0080-restore-at-launch.md)): `Tab.state` costs work per selected row.
- **Ask before reloading a drifted window** — not done: Dylan asked for going back to load the
  saved state, and the dot shows beforehand that the window differs.

## Consequences

Saved workspaces of the build before this change are not carried over: their files are window
files now, so a named one that was open comes back unsaved and a closed one is deleted at the
first launch as a stray window file. Each reload lists the snapshot's folders again. A drifted
window's state is lost on reload unless saved first; the edited dot is the only warning.
