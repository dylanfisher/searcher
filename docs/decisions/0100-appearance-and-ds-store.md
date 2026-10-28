# 0100. The app's appearance and hiding .DS_Store are app-wide settings in the View menu

- **Date:** 2026-10-25
- **Status:** accepted

## Context

Dylan asked for two preferences on 2026-10-25: "make sure you can manually specify color mode in
searcher (auto, dark, light)" and "add setting to hide .DS_Store even if hidden files are
enabled". [0031](0031-view-settings.md) puts view preferences in `Settings`, app-wide, in
`UserDefaults`, with one sort path: `Listing` keeps hidden entries and gives them no row. There
is no Settings window yet (M5b.8), and every command has a menu item
([0060](0060-menu-items-for-every-command.md)).

## Decision

- **Two settings.** `Settings.appearance` is `auto`, `light` or `dark`, stored as that string,
  Auto by default. A stored value that isn't a string, or isn't one of the three names, is
  removed and reads as Auto, as 0031 does for a Boolean of the wrong type. `Settings.hideDSStore`
  is a Boolean, on by default.
- **Menu items.** View ▸ Always Hide .DS_Store sits under Show Hidden Files and has a check mark
  while it is on. View ▸ Appearance is a submenu of Auto Appearance, Light Appearance and Dark
  Appearance, in System Settings' order, with a check mark on the one set. The titles name the
  appearance in full so the palette, which lists commands by title, reads them alone. None has a
  key. Like the other view toggles they run through the focused pane, so they are off while no
  browser window is open.
- **Appearance.** `Settings.applyAppearance(to:)` sets `NSApp.appearance` to nil for Auto, `aqua`
  for Light and `darkAqua` for Dark, at launch before any window opens and after each change. A
  nil appearance follows the system's own setting as it changes. Tests pass a view instead of
  `NSApp`, since the app's appearance is shared by every test in the process. Views that draw
  read dynamic system colors against their own `effectiveAppearance`; the one that didn't was the
  pane's focus ring, a layer border whose `CGColor` was resolved once when it was set.
  `PaneContainerView` resolves it again on `viewDidChangeEffectiveAppearance`. The grips draw
  nothing, and the chevrons, badges, preview text, path bar and palette backdrop use dynamic
  colors, tints or system materials, which follow on their own.
- **.DS_Store is filtered where hidden entries are.** `Listing` takes `hidesDSStore` beside
  `showsHidden`; an entry named exactly `.DS_Store`, compared by bytes, has no row while it is on.
  With hidden files off it is hidden as any dot name is. Loads, sorts and patches pass it as they
  pass `showsHidden`, and the pane treats a change like a hidden-files toggle: it sorts a copy off
  the main thread, resolves the selection as after a load, and drops names waiting to be selected.
  Select All, type-to-select, the status bar's counts and column view read the rows, so they skip
  it with no code of their own. The palette's path results list folders only, so they never
  showed it. Copy, move, trash and folder sizes work on the file system, not on rows, and are
  unchanged.
- **On by default, as Finder hides it.** Finder doesn't list `.DS_Store` with hidden files
  shown (Cmd-Shift-. or `AppleShowAllFiles`); Dylan checked by hand on 2026-10-25.

- **Columns Start at Home Folder.** (Amended 2026-10-25, Dylan: "add a preference to show
  directories relative to root user (like finder) instead of / root": `Settings.columnsStartAtHome`
  is a Boolean, on by default, stored and discarded like `hideDSStore`. View ▸ Columns Start at
  Home Folder sits under as Columns, since it changes column view only, with a check mark while
  it is on and no key. What it does is in [0103](0103-column-trail-from-the-root.md).
  `Settings.home`, the home folder, isn't stored: the app takes it from `NSHomeDirectory()` once,
  and tests pass their own.)

## Alternatives considered

- **Filter .DS_Store in the lister, or as a second filter beside `NameFilter`** — rejected: the
  lister would list the folder again to show it, and a second filter would be a second place
  hidden-ness is decided. `NameFilter` changes move the cursor to the first row, which a view
  setting doesn't.
- **One enum in place of `showsHidden` and `hidesDSStore`** — rejected for now: it changes every
  caller of `Listing` and `ListingService`, tests and benches included, for the same behavior.
- **Read `NSApp.effectiveAppearance` in views** — rejected: a view's own appearance is what it is
  drawn in, and a window or view can override the app's.
- **Map the appearance in Browser** — rejected: Browser has no AppKit; Interface owns the mapping.

## Consequences

`UserDefaults` gains `hideDSStore`, `appearance` and `columnsStartAtHome`. With hidden files
shown and `.DS_Store` hidden, a sort by name walks the entries to drop it rather than taking the
name order as it is, an O(n) pass on the sort queue. Changing the system accent color doesn't
recolor a focus ring already drawn until the appearance changes or the ring is drawn again.

## Amendment: the config file (2026-10-27)

`appearance`, `hide-ds-store` and `columns-start-at-home` can be set in the config file
([0120](0120-config-format.md)). A value the app stored wins over the file's.

## Amendment: the config file is the settings (2026-10-27)

`appearance`, `hide-ds-store` and `columns-start-at-home` live in the config file
([0123](0123-config-is-the-settings.md)); a save of it applies at once, and the app's changes are
written to it. No stored value wins over the file.
