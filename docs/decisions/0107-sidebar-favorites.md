# 0107. Sidebar Favorites: bookmarks in Settings, kept while missing, and group toggles

- **Date:** 2026-10-25
- **Status:** accepted

## Context

Dylan, 2026-10-25: "sidebar should have a favorites feature, like finder (drag items into it to
have it show in favorites)" and "favorites, locations, and tags should all be configurable to be
hidden/turned off". The sidebar ([0086](0086-workspace-sidebar.md)) had one group, Workspaces.
Preferences live in `Settings`, the one type that reads and writes `UserDefaults`, where "stored
data has one shape. A missing key reads as the default. A value that isn't a Boolean is removed
and reads as the default too" ([0031](0031-view-settings.md)). No file-system call runs on the
main thread, and none in Interface (`scripts/arch`). Locations comes next as its own step (SB.2);
Tags needs search, which is on hold.

## Decision

- **A Favorites group above Workspaces,** as in Finder. It starts with Finder's defaults the app
  has: Applications, Desktop, Documents, Downloads and the home folder, which is `Settings.home`.
  AirDrop and Recents are left out; the app has neither.
- **`Settings.favorites` stores the list,** as a list of dictionaries, each with an absolute
  path string under `path` and, once made, a bookmark's data under `bookmark`, no other key, and
  no path twice (compared as `FileOperation.comparable` compares, without case). A missing key
  reads as the defaults. A value of any other shape, or with one item of another shape, is
  removed whole and reads as the defaults: one bad item says the list wasn't written by this
  shape. An empty list is a list: removing every favorite leaves none, and the defaults don't
  come back. The defaults aren't stored until the list first changes; looking for them makes
  their bookmarks, which changes it.
- **Bookmarks, with the last path beside them.** A bookmark follows an item that is moved or
  renamed, as Finder's sidebar does; a path alone would lose it. The path is kept too, so a row
  shows its name on the first frame without reading the disk, and an item whose bookmark can't
  be made yet (a default folder that doesn't exist) still has a row. `Favorite.resolve` runs on a
  `BlockingCallThread` ([0038](0038-slow-volumes.md)): it resolves the bookmark without mounting
  or UI. When there is no bookmark, or it doesn't resolve, or it leads into a Trash or to
  nothing, it looks at the path instead, and an item there gets a bookmark of its own, so a
  folder deleted and made again at the same path is found; a folder replaced by a file at the
  same path becomes a favorite of that file. A stale bookmark is made again. It
  says whether the item is a folder or a file, following a symbolic link to what it points at,
  as Finder opens a link to a folder as the folder; a broken link or a loop of links is missing,
  and a package is a file
  ([0093](0093-packages-are-files.md)). A path the new one only names another way, as `/tmp`
  names `/private/tmp`, or a link names its target, is kept as it was. An item found at a path
  another favorite has leaves the list, so no path is in it twice; the item itself doesn't
  count, so a rename that changes only case keeps it.
- **When items are looked for.** `Favorites.refresh` looks for every item as the app becomes
  active, the launch included, since items move while another app is in front. An item already
  being looked for isn't looked for twice; one removed and added again meanwhile is looked for
  again once the first find lands, since that find was for the favorite removed. A click or Return
  looks for the item first, then opens it, so a favorite moved since the last refresh opens where
  it is now.
- **A missing item stays, greyed.** One found neither through its bookmark nor at its path, where
  an item in a Trash (`.Trash`, `.Trashes`) counts as not found, shows greyed, its VoiceOver label
  ending "not found", and opens nothing. It comes back as soon as it is found again, as a share's
  or an ejected disk's favorite does once mounted and the app is next activated, or on a click.
  Removing an item the user may want back, because a disk is ejected, would lose data for a
  passing state. Finder's behavior for a deleted favorite wasn't checked by hand; this is the
  choice made. A missing item keeps its bookmark, so one put back from the Trash is found again.
- **Opening.** A folder shows in the window's focused pane (`Pane.navigate`), its column view
  starting its trail there as any navigation does ([0103](0103-column-trail-from-the-root.md));
  a file or package opens in its app, as a double-click on it does. Only the latest open acts.
- **Rows.** Each shows its name, the path's last component, and an icon with no disk read:
  Finder's symbols for the five defaults by path, a folder symbol for other folders, and the
  type's icon from `TypeIconCache` by extension for a file. Localized display names aren't read.
- **Drags in.** File URLs from a pane, Finder or any app dropped between favorites are added
  there, in order, leaving out those already listed; a drop on a favorite goes before it, and one
  on the group's row, or in the gap between the last favorite and the next group, at its end. A
  drag of only favorites already listed is refused. The drag shows no badge where the source
  allows (`.generic`), since nothing is copied or moved. Nothing drops among the workspaces.
  Dropping onto a favorite folder doesn't copy into it, as Finder's sidebar would; that is left
  for later.
- **Reordering and removing.** A favorite drags as its path under a type of the app's own
  (`com.dylanfisher.searcher.favorite`), with no file URL, so a pane or another app never takes
  it as a file to copy or move. Dropped within any window's Favorites it moves there. Dropped
  where nothing takes it, outside every shown window's sidebar, it leaves the list, as Finder's
  does; it doesn't slide back. Dropped on another shown window's sidebar, its Workspaces rows
  included, it stays; a minimized or ordered-out window's sidebar doesn't count.
- **A cancelled drag keeps the favorite,** as with Esc, as Finder keeps it. AppKit reports a
  cancel and a drop on nothing alike, with no operation, and the window server runs the drag,
  so the app's current event at the session's end may still be the last mouse-dragged one and
  can't be relied on. The sidebar takes the drag as cancelled when the window server's last key
  down (`CGEventSource.secondsSinceLastEventType`) came after the drag began, or the mouse
  button is still down: Esc cancels while the button is held, and a drop is the button's
  release. The key down covers a user who lets go of the button before the session's end
  reaches the app, which the button alone would turn into a removal. Any other key pressed
  during the drag also keeps the favorite, which errs toward keeping it. `NSDraggingSession`
  has no cancel state, and the drag's last position is the pointer's either way. Neither signal
  was checked with a real drag: a test can't run one without moving the user's pointer, so it
  is a hand check, and the tests replace the check.
- **No poof, and the menu.** The cursor shows no poof: AppKit's `NSShowAnimationEffect` is
  deprecated, and the cursor would need the outline view's drag source methods. Remove from
  Sidebar in a favorite's context menu removes a favorite too.
- **Every window follows.** One `Favorites` is shared by every window, as the `WorkspaceList`
  is; a list change is a `Settings` change, which every sidebar observes, and a change of what
  an item was found to be runs `Favorites`' own observers.
- **Group toggles.** `Settings.showsFavoritesInSidebar` and `showsWorkspacesInSidebar`, both on
  by default, stored and discarded as 0031's Booleans. There is no Settings window yet (M5b.8),
  so View ▸ Show Favorites in Sidebar and Show Workspaces in Sidebar sit under Focus Sidebar,
  with check marks, as the other settings' items are ([0100](0100-appearance-and-ds-store.md)).
  A hidden group has no rows; one shown again is expanded. With both off the sidebar is empty.
  A Locations toggle comes with the Locations group (SB.2).
- **Keys.** The list keeps its keys as 0089 has them; group rows can't be selected, so the arrows
  move between the groups' rows. Return opens a favorite as a click does. The list's VoiceOver
  label is now "Sidebar".

## Alternatives considered

- **Paths only** — rejected: a favorite renamed or moved in Finder would go missing.
- **Bookmarks only** — rejected: the rows couldn't show a name before a resolve off the main
  thread, so every launch would show the group empty for a moment, and a default folder that
  doesn't exist couldn't be listed.
- **Drop a missing item** — rejected: an ejected disk or a share that isn't mounted would cost
  its favorite.
- **Look for the items on every window's focus or every key** — rejected: once per activation
  and once per open keep the reads off any path a key press takes (B6).
- **A drag of a favorite as its file URL** — rejected: dropped on a pane it would move or copy
  the item itself.

## Consequences

A favorite moved while the app is active shows its old name until the next activation or a
click on it. A mount while the app is active doesn't un-grey a favorite until then either.
`Settings` now stores Data in a preference.
