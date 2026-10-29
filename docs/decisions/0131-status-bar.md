# 0131. The status bar: Finder's item count and free space along the window's bottom, on Cmd-/

- **Date:** 2026-10-28
- **Status:** accepted

## Context

Dylan, 2026-10-28: "we need the toggleable status bar (cmd+/) like finder (shows item count and
space by default)". Finder's macOS 26 window in column view (`tmp/shots/fb-1028b-2.jpg`) has a
bar about 28 points tall along its bottom edge, right of the floating sidebar, reading
"6 items, 789.74 GB available" in centred secondary text. The window is titled "images", the
folder selected in the second column, and the six items are that folder's: gif, jpeg, png,
raw, svg and tiff. [0128](0128-finder-window-chrome.md) gave the window a unified toolbar and a
full-size content view, hung the content from the safe area, and titled the window after
`Pane.titleLocation`. Each pane already has a path bar ending in `PaneStatusView`, its spinner
and its slow or offline note ([0052](0052-pane-status.md)).

Measured on this Mac with `NSURL` resource values, against `df -H` and the screenshot:

| Volume | `volumeAvailableCapacityForImportantUsage` | `volumeAvailableCapacity` | `df -H` |
|---|---|---|---|
| `/` (APFS) | 788.27 GB | 717.53 GB | 718G |
| `/Volumes/main` (SMB) | 0 | 30.55 TB | |

Finder's 789.74 GB, taken earlier the same day, matches the first column, which counts the
space the system can purge; `df` and plain free space don't.

## Decision

- **What it says**, in Finder's words: "6 items", "1 item", "0 items", or "2 of 6 selected"
  while rows are selected, then ", 789.74 GB available" once the space is known. Finder's own
  `LocalizableMerged.strings` gives "^0 items" for a count of 0 ("=0"), so an empty folder
  reads "0 items". `StatusBarText` holds the words. Counts use the system's locale, as
  Finder's do; the space is `ByteCountFormatter`'s file style, decimal with two decimals
  ("789.74 GB", "2 TB").
- **Which folder it counts: the one the window is titled after.** `Pane.statusPane` follows
  `titleLocation`: in list view the pane; in column view, with a folder selected alone in the
  focused column, the column showing that folder, as Finder counts "images" in the screenshot;
  else the focused column, with its selection. While the selected folder's column hasn't
  opened, as during a key-made selection waiting out `ColumnTrail.openDelay`, the line stays
  as it was.
- **It counts the rows the pane shows.** `Listing.count` already leaves out hidden files while
  they are hidden, `.DS_Store` while Always Hide .DS_Store is on, and the names a filter
  doesn't match, so the count is the list's, a filter's selection of its first row
  included. Only the selection the keys act on counts: the column of a folder selected in the
  focused column counts its rows alone, as Finder's "6 items" does for "images", even when
  that column keeps a selection from before, as after ← out of it. The selection is
  `Selection.rows(in:).count`; a provisional selection, which knows only the rows near the
  cursor, leaves the line as it was until it settles, which reports a change.
- **When it's written.** On every change of the focused pane or its columns
  (`PaneViewController.onStatusChange`), after every command and focus move (with the title),
  and when a free-space read lands. While a folder loads the line keeps the last folder's, as
  the path bar keeps its folder (0026). A folder that failed to list, or a server with no
  share, shows an empty line.
- **The free space** is `FreeSpace`, one per app. A volume is read the first time a bar asks
  for it, again when a bar moves onto it from another volume, and every known volume after
  any file operation finishes (`WorkspaceWindows.operationsChanged`), whichever way it ended.
  Nothing polls. A volume unmounted or mounted at a mount point is forgotten there
  (`VolumeEvents`), and one mounted is read afresh, since another disk mounted at the same
  `/Volumes/Backup` has the same `VolumeIdentity`. Each read is numbered: one that lands after
  its volume was forgotten, such as a read hung on a share that went away, is dropped, so it
  can't overwrite the new volume's value and doesn't keep the new volume from being read; it
  keeps its one thread until the call returns. Each read runs `availableCapacity(atPath:)` at
  the volume's mount point on a `BlockingCallThread` ([0038](0038-slow-volumes.md)), and the
  last value shows until the next lands. The value is the larger of the two measures in the
  table: the first on APFS, the second on an SMB share, which reports 0 for the first.
- **A share never blocks it.** A volume has one read in flight at most; asking again while it
  hangs starts nothing and the bar shows the count alone. A pane that is slow or offline asks
  for no read at all, and a folder whose volume a load hasn't read yet (`Pane.folderVolume`,
  read by the load's own `statfs`) has none to ask about. A read that fails is logged under
  `free-space`, shows no space, and isn't tried again until the next refresh, so a bar that
  changes on every key doesn't ask a failing volume each time.
- **One bar per window, the focused pane's.** Finder has one per window, and 0128 already makes
  the title, Back, Forward and the view buttons the focused pane's. The panes keep their path
  bars and `PaneStatusView` as they were: the status bar shows no spinner and no slow or
  offline note, so nothing is said twice. A bar per pane would put the same "available" in
  each half of a split.
- **The look is the system's.** On macOS 26 the bar is a bottom-aligned
  `NSSplitViewItemAccessoryViewController` of the panes' split view item: AppKit lays it along
  the window's bottom edge right of the sidebar and takes its height out of the content's safe
  area, as the toolbar takes the top. Its standard content insets padded it to 46 points, so
  they are off and it is 28, the height of Finder's bar and of the path bar. The label is the
  small system font in `secondaryLabelColor`, centred. Before macOS 26 the bar is a plain view at
  the content's bottom with the content's safe area ending above it.
- **Rows stay above it.** The tab host and the operations panel hang from the content's safe
  area bottom, as 0128 hung the top, so the panes end at the bar while it shows and at the
  window's bottom while it doesn't. Rows don't scroll under it as Finder's do; that goes with
  the toolbar's scroll inset in CH.2.
- **Show Status Bar / Hide Status Bar** (`ViewCommands.toggleStatusBar`) on Cmd-/, Finder's
  chord, which nothing else in the registry or the menus had. It is in the View menu after the
  toolbar's item, as in Finder, says what it would do, and works with the keys in a text field,
  as Hide Toolbar does. It toggles `Settings.showsStatusBar`, the `show-status-bar` preference
  in `Settings.preferences` with its comment, on by default as Dylan asked.

## Alternatives considered

- **`volumeAvailableCapacityForImportantUsage` alone** — rejected: an SMB share reads "Zero KB
  available".
- **`volumeAvailableCapacity` alone, or `statfs`** — rejected: 71 GB under Finder's figure on
  this Mac's startup disk.
- **Count the focused column in column view** — rejected: Finder counts the selected folder, the
  one the title names, so the bar and the title would disagree.
- **A bar per pane** — rejected above.
- **Re-read the space on a timer or on every folder change** — rejected: a timer polls a share
  that may be asleep, and a busy folder's patches would read the volume many times a second.
  A deletion outside the app shows at the next finished operation or move to another volume.
- **The accessory with its standard insets** — rejected: 46 points, taller than Finder's.
- **Keep the old line while a folder failed to list** — rejected: it would count a folder the
  pane no longer shows.

## Consequences

Each change of a pane writes one short line; nothing else runs on the main thread for it. A
volume read once is read again only on a move onto it, a mount there or after a file
operation, so space freed by another app shows late until then. Every test window reads its
stub volume's space from `/` unless it passes a `FreeSpace` of its own. The look can't be
checked in tests (0128): the frames, the safe area and the text are; the bar's background,
separator and the label's size against Finder's need a look by hand.

`statusPane` first used `selectedFolderColumn`, whose read of `Selection.members` trapped on a
click's unsettled selection in column view; it now compares the next column's location instead.

## Open questions for Dylan

- **Finder's number for a share.** The larger-of rule gives an SMB share its free space; that
  Finder shows the same for `main` wasn't checked.
