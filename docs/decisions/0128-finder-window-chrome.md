# 0128. Finder's window chrome: a unified toolbar, a floating sidebar and a title that follows

- **Date:** 2026-10-28
- **Status:** accepted
- **Amends:** [0086](0086-workspace-sidebar.md) (the sidebar's look),
  [0125](0125-workspace-open-is-a-back-step.md) ("the window has no Back or Forward toolbar
  buttons")

## Context

Dylan, 2026-10-28, beside his screenshots of Finder's macOS 26 window (`tmp/shots/fb-1028b-2.jpg`,
`fb-1028b-3.jpg`) and Searcher's plain centred title (`fb-1028b-4.jpg`):

1. "is it possible to have our sidebar look like the finder's liquid glass panel thing, but
   still be collapsible?"
2. "can searcher use the same more rounded corners as finder?"
3. "do we have plans to add back arrows? can we add an option ability to show the toolbar like
   finder (using liquid glass UI)"
4. "can we use the liquid glass title style instead of our basic title?"
5. "clicking a directory or otherwise selecting a directory should update the title right away."

The window was a titled window with a plain title bar, a split view controller with a sidebar
item (0086), and the title set to the focused pane's folder only when its location changed.

## Decision

- **AppKit's own chrome.** The window adds `.fullSizeContentView` and `toolbarStyle = .unified`,
  and gets an `NSToolbar`. On macOS 26 that alone gives the glass toolbar items, the larger
  window corners and the floating glass sidebar: the sidebar item was already
  `NSSplitViewItem(sidebarWithViewController:)`, which runs full height once the content view
  does. Nothing is drawn by hand; hover, pressed, focus and disabled looks are the system's.
- **Items** (`BrowserToolbar`): `.sidebarTrackingSeparator`, so the items start right of the
  sidebar; Back and Forward as one momentary segmented `NSToolbarItemGroup` marked
  `isNavigational`, which AppKit puts left of the title; a flexible space; and the view modes,
  List and Columns, as a select-one group showing the focused pane's mode. Searcher has no
  Share, tag or search item, so there are none. Each runs its command on the focused pane's
  table, as its menu item does from outside the tables (0089), so Back and Forward include the
  window's steps of 0125.
- **Enabling.** The items don't autovalidate. The window sets Back's and Forward's state from
  the commands' own `isEnabled` (`ListingTableView.canRunCommand`) whenever it shows its titles:
  after every command and on each change of the focused pane's location or title location.
- **One toolbar identifier** for every window, so AppKit shows and hides them together.
  `autosavesConfiguration` is off and customization is off: the config file holds the state.
- **Hide Toolbar / Show Toolbar** (`ViewCommands.toggleToolbar`) in the View menu after the
  sidebar's items, its title saying what it would do, as Finder's does. It toggles
  `Settings.showsToolbar`, a preference in `Settings.preferences` under `show-toolbar` with its
  comment, on by default as in Finder. It works with the keys in a text field, as Hide Sidebar
  does. Hidden, the window keeps a title bar with the title; Back and Forward stay in the Go
  menu and on Cmd-[ and Cmd-].
- **No default chord.** Finder's Hide Toolbar is Option-Command-T, but that is Open Terminal
  Here here (0035), and the registry refuses two commands on one chord. Moving Open Terminal
  Here is Dylan's call, as moving Calculate Sizes was in 0086's amendment. Until then the user
  can bind any chord in the config file's `shortcuts`. **Needs Dylan.**
- **Content below the bar.** The config banner and the tab strip hang from the content view's
  safe area, so the panes start under the toolbar, or under the title bar while it is hidden.
  Content doesn't scroll under the glass as Finder's does (`fb-1028b-3`); that needs the lists
  to take the bar as a scroll inset, which goes with the path bar's glass look (CH.2).
- **Corners.** Measured in a window on the second display: the corner radius is 26 points with
  the toolbar and 16 without, AppKit's radii for a toolbar window and a title-bar window, as in
  Finder. The window's frame stays the same when the toolbar hides or shows; only the content
  layout rect changes (598 to 618 points high in a 650-point window).
- **The title** is `Pane.titleLocation`: in list view the pane's folder; in column view the
  folder selected alone in the focused column (`ColumnTrail.selectedFolder`), else the focused
  column's folder, as Finder titles a column view window after its selected folder
  (`fb-1028b-2`). It changes in the same turn as the selection: `PaneViewController` reports
  `onTitleChange` from the pane's change, before the folder's column opens or lists, so a
  key-made selection waiting out `ColumnTrail.openDelay` titles the window at once too. The tab
  strip titles each tab the same way. With split panes the title and the buttons are the
  focused pane's.

## Alternatives considered

- **Back and Forward as two plain bordered items in an `NSToolbarItemGroup`** — rejected: AppKit
  on macOS 26 throws while laying out a group of custom subitems ("Unable to install
  constraint on view"), and the segmented group is the control Finder shows.
- **Hand-drawn glass** (`NSGlassEffectView`) for the bar or the sidebar — rejected: the
  system gives both with the unified toolbar, and a copy would drift from it.
- **Take Option-Command-T from Open Terminal Here** — not done without Dylan (above).
- **Title from the opened column** (the pane's location after → into it) — rejected: a click
  on a folder leaves the keys in its column, so the title would stay on the parent, unlike
  Finder.

## Consequences

- A stored new-window size is now the frame's size: with a full-size content view the content
  rect is the frame. A size stored before this is read the same way, so the first new window
  after the update is a title bar shorter than before; the next resize stores the new shape.
- The tab strip and the panes start 52 points below the window's top while the toolbar shows,
  and 32 while it is hidden.
- Tests can't capture the glass: the test host has no screen recording permission, and a
  view's `cacheDisplay` doesn't draw backdrop layers. Layout, titles, radii and the item states
  are checked; the look needs a check by hand.
