# 0080. Restore at launch: save on a quiet moment, rebuild from the session

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M5a.2 saves every workspace change through `WorkspaceStore` ([0078](0078-workspace-store.md))
and reopens the session's windows at launch. `Tab.state` costs work per selected row (Select All
in W2 names 100k rows), and a pane changes on every load batch, sort and selection, so reading
the state on each change would put that work on the main thread many times a second. B1 (500 ms)
runs from a cold launch to every restored window on screen with the key window's focused pane
showing rows, and the store's read is inside it. A restored folder may be gone, or on a disk or
share that isn't mounted; nothing may wait on it. The store reports problems through a closure,
from its load and from writes in the background, and they must reach the user.

## Decision

- **Changes.** `Pane` reports each change to its tab as well as to its view (`onTabChange`),
  `Tab` reports its layout and panes' changes, and `Workspace.onChange` passes on those and its
  own tab strip's. `WorkspaceWindows` also counts its windows' moves, resizes and key changes,
  and the windows opening, closing and merging. A change only marks the workspace unsaved.
- **Saves.** Once no change has come for `saveDelay` (500 ms), or 5 s after the first unsaved
  change while they keep coming (folder sizes trickling in, a long drag), `WorkspaceWindows`
  reads the state of each unsaved workspace and the session once and hands the store what
  differs from what it last handed it. The store then writes a second later ([0078](0078-workspace-store.md)).
  Each batch is handed over after the one before it, so an older state can't land after a newer
  one. The session lists the windows most recently active first; the first is the key window.
- **Quitting** saves what is unsaved and flushes the store first, inside the shared 2 s quit
  deadline ([0065](0065-operation-queue.md), [0075](0075-ask-before-quitting.md)), then cancels
  file operations and flushes the listing cache as before. Saving first means a copy that is
  slow to cancel can't cost the windows. The three waits share one race helper,
  `FirstToFinish.run`.
- **Launch.** The app delegate starts `WorkspaceStore.load()` as it is made; the store's actor
  reads the files while AppKit finishes launching. Once launched, it waits for that read and
  calls `WorkspaceWindows.restore`, which builds the windows from the session, front window
  first in the list, skipping each ID whose workspace didn't load. The key window's panes are
  made first and its workspace made active, so its focused pane's load is asked for first. No
  session, or none of its workspaces, opens the home window as before. Until `restore` runs,
  nothing is saved (`holdSavesUntilRestore`): a quit in that moment writes nothing, so the
  session on disk stays for the next launch, and a Dock click waits for the restore instead of
  opening a home window. The session as restored is taken as saved, so the first save after
  launch doesn't write it again.
- **Panes** start as saved: folder, view mode, sort, Back and Forward, and the selection by
  name, which the existing load path resolves as the rows arrive; a full listing drops names
  that are gone. A column-mode pane restores one column at its folder with the saved cursor,
  as `TabState` keeps only that folder. A folder that isn't there is the missing state
  (`ListingState.missingFolder`: a failed listing with ENOENT or ENOTDIR), shown with its path,
  and the pane stays at that path. An unmounted share's folder lists as missing until M5a.3.
- **Frames.** A saved frame is kept while at least 100 × 22 pt of its title bar is on an
  attached display, so the window can still be dragged; otherwise it is centered on the main
  display and shrunk to fit it.
- **Problems.** Every `StoreProblem` is logged and shown in one `Dialog.alert` as a sheet on the
  front window, its sentence per problem and an OK button, once a window is up. Problems that
  come while it shows, or while no window can take a sheet, wait and show together after.
  It uses `beginSheetModal`, unlike [0076](0076-dialogs.md)'s question sheets: it has one
  button and nothing to keep it up for.

## Alternatives considered

- **Save on every change** — rejected: `Tab.state` per load batch or key press is main-thread
  work proportional to the selection.
- **Save only at quit** — rejected: a crash or a forced quit would lose the whole session.
- **The quit question's app-modal alert for problems** — rejected: at launch it would hold the
  windows behind a modal session, and in the background it would interrupt whatever the user is
  doing in every window.
- **Restore in `applicationWillFinishLaunching`, reading the files there** — rejected: that
  reads on the main thread, which the app never does.

## Consequences

A crash loses the changes of the last 1.5 s, or up to 6 s while changes keep coming: the save
wait plus the store's write delay. Closing the last window and then quitting saves an empty
session, so the next launch opens the home window. The `restored-session` UI bench scenario
times B1 with 3 windows × 2 tabs × 4 panes; it writes the fixture in the same launch, unsynced,
so it times slightly more than a real launch.

## Amendment: the restored session in CI (2026-10-24)

The CI run (`./scripts/bench --ui`) now makes the `restored-session` scenario's 20 launches after
its own 20 and keeps their samples in the same `.build/bench-ui.json`, under their own field
(`UIBenchRecord.restoredSessionLaunch`) and case, "launch → restored windows, key window's
focused pane rows frame", which the scenario run names the same way. `compare-ui` therefore
judges it under the same history as every other UI case: report-only until its p95 stays within
10% across three runs on one branch, then failing over B1's 500 ms. The cold launch's own B1 case
keeps only the CI run's launches.

- **Alternatives considered.** A separate workflow step that runs the scenario and a `compare-ui`
  that merges a second record — rejected: a second file to download, upload and check for
  completeness, and a second argument to `compare-ui`, for the same history. A separate history
  for the scenario — rejected: two histories would need two artifacts or a merged format.
- **Cost.** About a minute more in the bench-ui job: a restored-session launch takes 1 to 3 s,
  as the bench window's launches do ([0022](0022-ui-bench-mode.md)), plus a cold process start.
  The job keeps its 20-minute timeout. Running `--ui` locally costs the same minute more.
