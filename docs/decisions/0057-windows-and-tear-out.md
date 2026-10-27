# 0057. Windows and tear-out: a workspace list, pane views that move, focus that travels

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M3.6b adds Cmd-N (new window), "Move pane to new window" and "Merge window into tab"
(`tmp/behavior.md`, Windows, tabs, panes). Until now the app delegate kept an array of
`BrowserWindowController`s and opened one only at launch and on a Dock click, both on the home
folder ([0021](0021-one-pane-window.md)); Cmd-N had no command. Each window made its own
workspace, and nothing knew the other windows. The step asks that panes and tabs move between
windows without being listed again. Gaining the focus lists a pane's folder again
([0048](0048-pane-load-priority.md)), and a context must be built on the selected tab's focused
pane, which the window keeps in step with the first responder ([0054](0054-tabs-in-window.md)).

## Decision

- **`WorkspaceList`** (Browser) holds the open workspaces, most recently active first. `add` puts
  a workspace first and makes it the only active one; `activate`, which `windowDidBecomeKey`
  calls, moves it first and makes the others inactive; `windowDidResignKey` still clears
  `isActive`. `CommandContext.workspaces` passes the list to the window commands.
- **Commands.** `WindowCommands` holds New Window (Cmd-N, File menu), Move Pane to New Window and
  Merge Window into Tab (Window menu, no chords). Each has one ID, in the registry and the menu,
  and all three are in the set the window controller runs from outside a pane's table, so they
  work from the filter field. New Window makes its pane with `Pane.newPane(at:)`, as New Tab
  does. Move is off with one pane in the window; merge is off with one window.
- **Move** takes the selected tab's focused pane out of its tab, open, with
  `Workspace.removeFocusedPane`, which returns a tab of that pane under the same `PaneID`. The
  tab closes with its last pane. **Merge** appends every tab, in order, to the first other
  workspace in the list, selects the tab that was selected in the source, makes that workspace
  active and drops the source (`WorkspaceList.merge`).
- **Focus travels with the pane.** The moved pane keeps `isFocused`: the source workspace
  forgets it without telling it it lost the focus and becomes inactive, since the keys go to the
  new window. `Workspace.updatePanes` takes a focused pane that is already focused as it is,
  without calling `didGainFocus`, so it isn't listed again. The source's remaining pane isn't
  focused, so it isn't listed either until its window is key again, as with any window switch.
- **`WorkspaceWindows`** (Interface) replaces the delegate's array: one controller per workspace
  in the list. After each command in any window it opens a window for each new workspace,
  cascaded from the window it came from, shows every window's workspace again, then closes the
  windows whose workspace left the list. A closed window drops its controller and workspace.
- **Pane views move with the pane.** A window making a view for a pane asks the others for the
  `PaneViewController` they already have for it (`handOver`). The old window drops it and
  updates its layout at once, then the new window links it to its own workspace. The pane keeps
  its table, scroll position, filter, columns and the folder monitor the view started; no new
  monitor starts. A window makes views for every tab, not only the selected one, so merged tabs
  take their views before their old window closes.
- **Lifetime.** A window that closes for good, by its close button or its last tab, closes every
  pane it still has (`Workspace.closeAllTabs`): their loads, size walks and watches stop then,
  not when the panes are freed, which left a walk held on a hung share or an FSEvents stream
  running until its own timeout. Move and merge hand their panes over first, so the panes they
  moved are no longer the window's. A merged-away workspace is closed (`Workspace.isClosed`): it
  closes no pane, leaves the panes alone when its window's key state changes, and its window
  shows nothing more and closes.
- **Cmd-N with no window** opens a window on the home folder, the folder the app opens at launch
  and on a Dock click. With no window the menu item reaches the app delegate, which handles only
  New Window. A window with the keys runs the command from its focused pane.

## Alternatives considered

- **Build new pane views in the new window** — rejected: a new table loses the scroll position,
  and a new view starts a second folder monitor, replacing the pane's without stopping it.
- **Call `didGainFocus` and skip the reload for a moved pane by a flag on the pane** — rejected:
  the workspace already decides who gains the focus, and a pane that never lost it has nothing to
  catch up on, which the existing `isFocused` says.
- **Merge selects the target window's own tab** — rejected: the user was looking at the source's
  tab, and keeping it selected keeps the focused pane where the keys were.
- **Cmd-N with no window opens the last closed window's folder** — not done: nothing remembers
  it yet, and window restore is a later step.
- **Leave closed windows' panes to be freed** — rejected: freeing doesn't stop in-flight work,
  so a closed window kept its share busy until the work timed out.
- **Notify the interface from `WorkspaceList` with callbacks** — rejected: the windows already
  show the model after every command (0054), and one pass after the command covers opening,
  merging and closing.

## Consequences

Every command now shows every window's workspace, not only its own. That is a dictionary check
per tab and window and does nothing costly when nothing changed.

The UI bench's window still opens through `BrowserWindowController(location:...)`, with a list
of its own; nothing there runs the window commands.

A moved pane's old window loses the first responder it had in that pane and gives it to its
newly focused pane, so model focus and first responder stay in step in both windows.

## Amendment: a new window takes the size last set by hand (2026-10-25)

Finder opens a new window at the size the user last gave a window by dragging its edge.
`BrowserWindowController.windowDidEndLiveResize` stores the window's content size in
`Settings.newWindowSize`: one key holding two numbers, 900 × 600 (`Settings.defaultWindowSize`)
until set, and anything else discarded and removed, as for the palette's place
([0031](0031-view-settings.md)). Zoom, full screen and a restored frame are not live resizes and
store nothing, so a zoomed window doesn't make every later window screen-sized. Every window the
app makes without a saved frame uses the size: New Window, a new workspace and a pane moved out
into a window. `WorkspaceWindows.fitted` cascades it as before, then shrinks it to the display
most of it is on and moves it inside that display's visible frame, so a size set on a large
display opens whole on a small one. A window opened from a saved frame keeps that frame
([0080](0080-restore-at-launch.md)).

## Amendment: a new window takes the frame last set by hand (2026-10-26)

Dylan: "new windows should open at the position of the last window you modified." The key that
held the size, `Settings.newWindowSize`, is now `Settings.newWindowFrame`, the only key: four
numbers, the origin of the window's frame and the size of its content, and anything else
discarded and removed. Nothing is stored until a window is first changed by hand, and
`newWindowSize` reads the stored size or 900 × 600. A window stores its frame when the user ends
a live resize, or drags it by the title bar.

The drag is told from a move the app makes (restore, cascade, `fitted`, zoom, full screen,
tests) by `windowWillMove`, which AppKit sends as a drag starts, and the left button: after it, each
`windowDidMove` with the button down stores the frame, and the first one with it up ends the
claim. A drag leaves its claim set, since its last step is made before the button comes up, so
the window's `sendEvent` also ends it at every left mouse down, ahead of the event's handling:
the mouse down that starts a title-bar drag is handled, and so clears the flag, before
`windowWillMove` sets it, and a move the app makes after a later click finds it clear. A live
resize's end ends the claim too. The last step of a drag is the drop, so the frame stored is
where the window was dropped; macOS's drag-to-edge tiling snaps after the button comes up, so
the stored frame is the position before the snap. No event monitor, no timer, and nothing that
reads the current event's type.

A new window without a saved frame opens at the stored frame when no open window has its top
left there; if one does, it steps down and right by the system's cascade offset
(`cascadeTopLeft`), again for each open window at the place it lands, as Finder's new windows
step from the last one. With no stored frame it centers and cascades from the front window as
before. `fitted` then keeps it on a display, so a frame stored on a display that is gone opens
on one that is there. A restored window keeps its saved frame, as before.

The key `newWindowSize` this replaced is no longer read, and its size is not carried over. A
value left under it is not removed either: before the first release, stored data keeps no
compatibility code (AGENTS.md).
