# 0125. Opening a saved workspace into its window is a Back step of that window

- **Date:** 2026-10-27
- **Status:** accepted
- **Amends:** [0033](0033-history-and-go-to-folder.md) (what Back and Forward step through),
  [0078](0078-workspace-store.md) (what a window file keeps),
  [0088](0088-workspace-snapshots.md) (going to a saved workspace, the edited dot)

## Context

Dylan, 2026-10-27: "if possible, clicking on a workspace that is within the same window should
support back (e.g. you click on a workspace and then go back to the previous state). if the
workspace opened in a new window it wouldn't make sense to go back, though."

When opening a workspace replaces what a window shows, from 0088 and the code
(`WorkspaceWindows.open(savedWorkspace:)`, `showSnapshot`):

- 0088: "with no window linked it opens one from the snapshot, as before; with one linked it
  brings it forward and, if its state differs from the snapshot, shows the snapshot in it. When
  only the frame differs, the window moves to the snapshot's frame and keeps its panes, scroll
  positions and histories. Otherwise `Workspace.reload` closes every tab it had, panes and all,
  and puts in tabs rebuilt from the snapshot". 0086's amendment says the same: "opening a saved
  workspace whose window is open loads its snapshot into it".
- So no workspace ever loads into a window other than its own. A sidebar or palette click in a
  window on its own workspace's row replaces that window's tabs when it has drifted. A click on
  another workspace's row opens a new window for a closed one, or brings the other one's window
  forward, and reloads that window in place if it has drifted.
- 0088 also says: "A drifted window's state is lost on reload unless saved first; the edited dot
  is the only warning."

The history there was:

- **Per pane:** Back and Forward (0033: "a history per pane"). Each way keeps its nearest 500
  entries (0033's 2026-10-27 amendment: "each way keeps its nearest 500 entries
  (`History.limit`)"). One Back step restores one folder and the name under the cursor there.
- **Saved with the window:** 0042 says `TabState` keeps each pane's "Back and Forward entries,
  each a path and the name under the cursor there", and 0080: "Panes start as saved: folder, view
  mode, sort, Back and Forward, and the selection by name".
- **Per tab, not saved:** the selection history, ⌘U (0112: "One history per tab";
  "Kept from 0077: … and no persistence").
- **Rebuilt panes:** 0088: "The rebuilt panes are new, so their selection history starts
  empty".

No history spans a window.

## Decision

- **A window's own Back and Forward.** `Workspace.history` (`WorkspaceHistory`) holds steps,
  each what the window showed: every tab as `TabState`, which keeps the layout and split,
  folders, view modes, sorts, selections by name, column widths and each pane's own Back and
  Forward, plus the selected tab and whether the sidebar shows. Each way keeps its nearest 10
  steps (`WorkspaceHistory.limit`); each step holds up to 1,000 history entries per pane, so the
  limit bounds the window file. Panes' own histories keep their 500 each way inside a step.
- **Opening a saved workspace into its window is a step.** When `showSnapshot` rebuilds the
  window's tabs, `Workspace.open` first keeps what the window showed as a Back step and ends the
  window's way forward. That covers a click in the window's own sidebar or palette, and a click
  in another window on this window's workspace. The step belongs to the window whose tabs were
  replaced, whichever window the click came from.
- **What adds no step.**
  - A workspace opened in a new window: nothing was replaced.
  - A window that already shows its snapshot: nothing is replaced.
  - A window that differed only in its frame or column widths: its panes stay, so there is
    nothing to step back to.
- **Back walks the pane's own steps, then the window's.** Back runs `Pane.goBack` while the
  focused pane can, and `Workspace.stepBack` once it can't; Forward is the same with Forward. The
  menu items are on when either can (`NavigationCommands`). To make "click, then Back" return at
  once, `open` gives the rebuilt panes no Back or Forward: the snapshot's own pane histories are
  not used in the window it opens into. A new window opened from the snapshot still gets them.
- **One navigation model.**
  - Opening is a navigation of every pane, so the panes of the step it keeps lose their way
    forward, as `History.leave` ends a pane's. After the window's Back, Forward in the focused
    pane is then the window's, not a folder that pane had stepped back from.
  - A navigation in any pane of the window (`Pane.recordLeaving`, every `History.leave`) ends the
    window's way forward, as in Finder and a browser.
  - The window's Back keeps what the window shows, with its panes' histories, as the way forward.
    So Forward returns to the workspace as it was when Back was pressed, including folders
    visited in it since the open.
- **Back and Forward never move the window.** A step has no frame. The window stays where the
  snapshot put it, or where the user moved it since. Display changes can't affect a step.
- **The edited dot ignores Back and Forward.** The comparison with the snapshot
  (`WorkspaceWindows.differs`, and `showSnapshot`'s choice of what to do) now leaves out the
  window's steps and every pane's Back and Forward (`WorkspaceState.withoutHistories`). Neither
  shows in the window, and the window just opened has none while its snapshot keeps the panes'.
  Without this the dot would show right after an open, and the next click would reload again.
- **Saved with the window, not with the snapshot.** `WorkspaceState.history` is written to the
  window's file and restored at launch with the window, as panes' Back and Forward are. Save
  Workspace keeps none in the snapshot. A snapshot file with steps is a file of another shape:
  deleted and reported, as one without a name is.
- **The dot after a step.** The window's Back or Forward sets the edited dot at once
  (`Workspace.onStep`), as a reload does.

### Edge cases

- **A folder of a step was deleted, or is on an ejected volume or share.** The pane comes back at
  its path in the missing state, as a restored pane does ([0080](0080-restore-at-launch.md)) and
  as Back to a gone folder does ([0033](0033-history-and-go-to-folder.md): "it isn't skipped or
  removed from the history").
- **The workspace is renamed.** A step holds no ID or name; the window keeps its current name
  through Back and Forward.
- **The workspace is deleted.** Its window closes ([0082](0082-saved-workspaces.md)), and its
  steps go with it.
- **Move Pane to New Window.** The new window starts with no steps. The window it left keeps
  its own. A step that still holds the moved pane's ID rebuilds a new pane under it, and the
  moved one stays where it is (0088: "A window hands a pane's view controller over only to that
  same pane").
- **Merge Window into Tab.** The window that takes the tabs keeps its steps. Its Back then
  replaces the merged tabs too, and its Forward brings them back. The merged window's own steps
  go with it, as its window closes.
- **A different number of tabs.** A step holds every tab, so a step with three tabs replaces a
  window of one. Nothing pairs tabs by index.
- **Back pressed while folders still list.** A step keeps selections by name. `Tab.state` gives
  a settled selection of names as it is (0078), so a pane still loading keeps the names it will
  select.
- **A pane split, or a tab opened, after the open.** Its pane has no Back of its own, so Back
  there steps the window, closing it, and Forward brings it back.

### What it doesn't cover

- **Scroll positions, ⌘U's selection steps, and columns right of the focused one.** None of
  them is in `TabState`. Rebuilt panes start without them: restoring the selection scrolls to
  it ([0078](0078-workspace-store.md)), and column view rebuilds its trail from the root to the
  focused folder ([0103](0103-column-trail-from-the-root.md)). A step can't keep live panes: each
  would keep listing and watching its folder while hidden.
- **The window's frame.** A step has none (above).
- **The snapshot's own pane histories** in the window it opens into (above).
- **Forward after a new navigation.** A new navigation ends it, as it ends a pane's.
- **More than 10 steps each way.** The farthest go.

## Alternatives considered

- **Keep the snapshot's pane histories and mark, per pane, where the open happened.** Rejected:
  the marks would have to follow each pane's 500-entry trimming, live in every step and the
  window file, and stay out of the dot's comparison. The snapshot's old entries would still be
  out of reach while the window step stands.
- **Keep the old tabs' panes open and hidden, and swap them back on Back.** Rejected: hidden
  panes keep their loads, monitors and size walks running, and a step could not be saved for the
  next launch.
- **No step when another window's click reloads this one.** The brief read the user's "if the
  workspace opened in a new window it wouldn't make sense to go back" as also covering a window
  brought forward. Rejected: that window's tabs are replaced in place, as with a click in its
  own sidebar, and 0088 loses its drift with only the dot as warning. Needs Dylan.
- **A frame in each step.** Rejected: Back and Forward would move the window on a key press,
  a frame-only open would have to be a step too, and a step's frame could be on a display since
  removed.
- **Not saving steps across a launch,** as ⌘U's aren't. Rejected: Back and Forward are saved
  with the panes, and a step lost at relaunch would leave Back in the opened window with nothing
  to do.

## Consequences

- A window file grows by its steps: usually a few kilobytes, at most 10 steps each way.
- `Workspace.restoreTab`, set by `WorkspaceWindows` for every window it makes, rebuilds tabs for
  `open` and for the window's Back and Forward.
- Back after opening a workspace in its own window returns to what the window showed, and Forward
  re-applies the workspace. The menu items' states follow from `CommandBinding.isEnabled`; the
  window has no Back or Forward toolbar buttons.
