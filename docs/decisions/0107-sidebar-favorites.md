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
  or UI, else looks at the path, makes a bookmark when there is none or the old one is stale, and
  says whether the item is a folder or a file; a package is a file
  ([0093](0093-packages-are-files.md)). A path the new one only names another way, as `/tmp`
  names `/private/tmp`, is kept as it was. An item found at a path another favorite has leaves
  the list, so no path is in it twice.
- **When items are looked for.** `Favorites.refresh` looks for every item as the app becomes
  active, the launch included, since items move while another app is in front. An item already
  being looked for isn't looked for twice. A click or Return looks for the item first, then
  opens it, so a favorite moved since the last refresh opens where it is now.
- **A missing item stays, greyed.** One whose bookmark doesn't resolve, with nothing at its path,
  or in a Trash (`.Trash`, `.Trashes`) shows greyed, its VoiceOver label ending "not found", and
  opens nothing. It comes back as soon as it is found again, as a share's or an ejected disk's
  favorite does once mounted and the app is next activated, or on a click. Removing an item the
  user may want back, because a disk is ejected, would lose data for a passing state. Finder's
  behavior for a deleted favorite wasn't checked by hand; this is the choice made.
- **Opening.** A folder shows in the window's focused pane (`Pane.navigate`), its column view
  starting its trail there as any navigation does ([0103](0103-column-trail-from-the-root.md));
  a file or package opens in its app, as a double-click on it does. Only the latest open acts.
- **Rows.** Each shows its name, the path's last component, and an icon with no disk read:
  Finder's symbols for the five defaults by path, a folder symbol for other folders, and the
  type's icon from `TypeIconCache` by extension for a file. Localized display names aren't read.
- **Drags in.** File URLs from a pane, Finder or any app dropped between favorites are added
  there, in order, leaving out those already listed; a drop on a favorite goes before it, and
  one on the group's row at its end. A drag of only favorites already listed is refused. The
  drag shows no badge where the source allows (`.generic`), since nothing is copied or moved.
  Nothing drops among the workspaces. Dropping onto a favorite folder doesn't copy into it, as
  Finder's sidebar would; that is left for later.
- **Reordering and removing.** A favorite drags as its path under a type of the app's own
  (`com.dylanfisher.searcher.favorite`), with no file URL, so a pane or another app never takes
  it as a file to copy or move. Dropped within any window's Favorites it moves there. Dropped
  anywhere outside the sidebar where nothing takes it, it leaves the list, as Finder's does; it
  doesn't slide back. The cursor shows no poof: AppKit's `NSShowAnimationEffect` is deprecated,
  and the cursor would need the outline view's drag source methods. Remove from Sidebar in a
  favorite's context menu removes it too.
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
