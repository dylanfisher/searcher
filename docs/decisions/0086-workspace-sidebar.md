# 0086. Workspace sidebar: a Finder-style source list, on Control-Command-S

- **Date:** 2026-10-24
- **Status:** accepted
- **2026-10-24:** Focus Sidebar has Command-0 and gives the keys back when pressed in the
  sidebar, and opening a saved workspace whose window is open loads its snapshot into it; see
  [0088](0088-workspace-snapshots.md).

## Context

M5a.8 adds a sidebar that lists the saved workspaces ([0082](0082-saved-workspaces.md)), marks
the open ones and opens one on a click or Return. The plan gave it Control-Command-S, Finder's
Show Sidebar chord, but M4.22 bound that chord to Calculate Sizes, and the registry refuses two
commands on one chord. Each window already stored whether its sidebar shows
(`WorkspaceState.showsSidebar`, [0078](0078-workspace-store.md)), with nothing to show.

## Decision

- **A source list in a split view, as Finder's.** `BrowserWindowController` puts its content in
  an `NSSplitViewController`: a sidebar item (`NSSplitViewItem(sidebarWithViewController:)`) left
  of the tab strip, panes and operations panel. It gets AppKit's sidebar material, divider and
  collapse animation, and the user can drag it closed. The list is an `NSOutlineView` in the
  `.sourceList` style, with one group row, Workspaces, which collapses as Finder's groups do.
  Row height follows the system's sidebar icon size setting (`rowSizeStyle = .default`).
- **Rows follow the list.** `WorkspaceList.observeSaved` runs its observers after naming,
  renaming, adding, opening, closing, merging and deleting; each window's sidebar reads `saved`
  and reloads only when it differs. Making a workspace active runs nothing, so a key press in a
  pane never touches the sidebar; B6 with it shown is still to be measured.
- **Open marks.** A dot at the row's end marks a workspace whose window is open, as the Dock
  marks a running app. The row's accessibility label says "open"; the dot is hidden from
  VoiceOver.
- **Selection is the window's own workspace,** as Finder's sidebar selects the window's place.
  A click on a row opens it (`WorkspaceWindows.open(savedWorkspace:)`: reopens a closed one,
  focuses an open one). With the keys in the list, the arrow keys only move the selection, so
  walking the list opens no windows, and Return opens the selected row.
- **Commands.** Show Sidebar / Hide Sidebar (`workspace.toggleSidebar`, in the View menu where
  Finder has it, its title saying which) sets `Workspace.showsSidebar`, which the window shows
  and the store saves. Focus Sidebar (`workspace.focusSidebar`, no chord) shows the sidebar and
  moves the keys into it; Esc gives them back to the focused pane and leaves the sidebar
  showing. While the sidebar has the keys, a command that redraws the window leaves them there,
  and hiding the sidebar moves them to the pane. Both commands' menu items work with the keys in
  the sidebar.
- **Drags and animations.** A drag of the divider that collapses or opens the sidebar sets
  `Workspace.showsSidebar`. The split view also resizes all through a command's animated
  collapse, with `isCollapsed` read at any point of the way, so the window ignores resizes
  until that animation's completion runs, then reads the final state once.
- **New windows follow the front window,** as Finder's do: New Window, Move Pane to New Window
  and a window opened at a folder show the sidebar if the most recently active window does.
- **Tab and Shift-Tab.** The window puts the sidebar's list into the key view loop just before
  the focused pane's key view, and moves it when the focus moves, so Shift-Tab in the pane and
  Tab in the sidebar go between the two. A hidden sidebar is passed over.
- **Option-Command-S for Show Sidebar.** Control-Command-S stayed Calculate Sizes.
  Option-Command-S was Finder's Hide Sidebar chord in earlier macOS versions, and nothing here
  used it. Giving the sidebar Finder's current chord meant moving Calculate Sizes, which was
  Dylan's call (see the amendment below).
- **Menu titles from bindings.** A command item's title now comes from its binding's `title`
  when it has one, as Undo's did; this also makes Name Workspace… read Rename Workspace… once
  named, which 0082 described but the menu didn't show.

## Alternatives considered

- **A plain `NSSplitView` in the content view** — rejected: it would need its own collapse
  animation, divider drag-to-collapse and sidebar material, which the split view controller
  gives.
- **Open a row on selection change** — rejected: the arrow keys would open or raise a window per
  row passed.
- **Refresh the sidebar from `showWorkspace`** — rejected: it runs after every command,
  including each arrow key in a pane, and misses changes made outside commands, such as a
  window closed by its button or a rename from the name sheet.

## Consequences

With no window open, a new window opens with the sidebar hidden; restored and reopened windows
show it as saved. With no saved workspace the sidebar shows only its group row.

## Amendment: Control-Command-S (2026-10-24)

Dylan decided the sidebar takes Finder's chord, Control-Command-S. Calculate Sizes moved to
Option-Command-S ([0043](0043-folder-sizes.md)); no other command uses it and it is not a
system-wide macOS shortcut. The Context and the bullet above describe the chord as first built.

## Amendment: B6 with the sidebar shown (2026-10-24)

The CI run's key launch now lists five saved workspaces, shows the sidebar by pressing the chord
`WorkspaceCommands.toggleSidebar` declares, read from the command so a later chord change can't
leave the bench pressing another command's keys, waits for its animation to end, presses ↓ 500
times on W2, a B6 case of its own ("W2 ↓ key with the sidebar shown → frame"), then hides it
again so the cases after it have the window's full width. It runs after the queue case and
before column view, in the plain `--ui` run CI makes, with no scenario of its own: one launch's
500 presses add about 10 s. Like any new UI case it is report-only until its p95 stays within
10% across three CI runs. The sidebar is no longer "still to be measured", but the run doesn't
check that the sidebar draws nothing during the presses, as the splits cases check the unfocused
panes.
