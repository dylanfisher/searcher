# 0086. Workspace sidebar: a Finder-style source list, on Option-Command-S

- **Date:** 2026-10-24
- **Status:** accepted

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
- **Option-Command-S for Show Sidebar.** Control-Command-S stays Calculate Sizes.
  Option-Command-S was Finder's Hide Sidebar chord in earlier macOS versions, and nothing here
  used it. Giving the sidebar Finder's current chord means moving Calculate Sizes, which is
  Dylan's call.
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

New windows open with the sidebar hidden, as `Workspace(tab:)` makes them; restored and reopened
windows show it as saved. With no saved workspace the sidebar shows only its group row. If
Calculate Sizes moves off Control-Command-S, `WorkspaceCommands.toggleSidebar` can take it in a
one-line change.
