# 0114. A connected server is a place: one sidebar row, its shares as its rows

- **Date:** 2026-10-26
- **Status:** proposed
- **Amends:** [0108](0108-sidebar-locations.md): "A share is listed by its mount point";
  [0026](0026-path-bar.md): "Which volume", for folders on a share;
  [0103](0103-column-trail-from-the-root.md): "Which root", for folders on a share.

## Context

Dylan, 2026-10-26, chose Finder's full behavior for network servers. With
`//dylan@HAL9000._smb._tcp.local/music` on `/Volumes/music` and `.../main` on `/Volumes/main`,
Finder's Locations lists one row, "HAL9000", with the `SidebarGenericFile` glyph and one eject
button that unmounts both shares; the shares get no rows of their own, and a click on the server
shows its shares. 0108's amendment found the grouping cheap: the mount source is in the mount
table (`VolumeIdentity.device`, `f_mntfromname`, read with `MNT_NOWAIT`), and the server's name is
the Bonjour instance name in it. The hard part is that `Location` is a path, and the listing,
the column trail, the path bar, history, the saved session, ⌘K, ⌘U
([0112](0112-position-history.md)), drops, file commands, Quick Look, tabs and windows all take
a pane's location to be a folder.

## Decision

- **Which shares make a server.** A volume belongs to a server when it is a browsable network
  volume mounted directly in `/Volumes`, where the system mounts shares, and its source names a
  host: `//[user@]host[:port]/share` (SMB, AFP), `scheme://[user@]host[:port]/…` (WebDAV) or
  `host:/path` (NFS). `VolumeIdentity.server` gives it, with no read. The server is the host,
  compared without case, so shares mounted by different users from one host are one server. Its
  name is the Bonjour instance name when the host is `<instance>._<service>._tcp.<domain>`, with
  `\DDD` and `\c` escapes and percent escapes undone ("HAL9000"), and the host as written
  otherwise ("192.168.1.5"). Any other volume, a share mounted elsewhere or whose source doesn't
  parse, keeps its own row as 0108 has it.
- **The model: `Location` gets a second case.** `enum Location { case folder(path: String),
  case server(Server) }`, keeping `init(path:)`. `Server` holds the host and gives the name.
  Every member has a server answer, so most users need nothing: `name` is the server's name,
  `parent` is nil, `ancestors` is `[self]`, and `child(named:)` is `/Volumes/<name>`, since a
  server's shares are the folders it has in `/Volumes`. `path` becomes `String?`, nil for a
  server, so the compiler lists every user of a path, and each one decides there: a user that
  touches the file system refuses a server or never receives one, and says which. `Location` is
  a value with no read, as before: the shares a server has now come from its listing, not from
  the location.
- **Each user of a location.**
  - Listing: `ListingService.load` of a server builds its listing from the mount table it already
    reads off the main thread (`mountedVolumes`, `MNT_NOWAIT`), asking no share: one `.directory`
    entry per share, named by its mount point's last component as 0108 names a share ("main 1"
    for a second mount). It takes no volume slot, no stall timers and no cache; it hands `full`
    at once. A server with no share mounted fails as not connected (`ENOTCONN`).
  - Pane: no folder monitor, no folder size walks, no recent listing or listing cache.
    `VolumeEvents` reloads every pane at a server on each mount and unmount, so the rows follow
    the shares. A pane at a server that is not connected shows "“HAL9000” isn't connected."
    where a folder's failure shows, and stays there, as a missing folder's pane does
    ([0080](0080-restore-at-launch.md)); it lists again when a share of it mounts. Panes inside
    a share that unmounts go offline as [0049](0049-volume-events.md) says.
  - Rows: a share in a server's listing shows CoreTypes' `GenericSharepoint` icon (read as
    `CoreTypesIcons` reads sidebar glyphs), Kind "Volume", and `--` for Size and Date Modified.
    The entries carry the Unix epoch as their date, which no view shows, so a date sort keeps
    name order.
  - Commands at a server: New Folder, Paste, Move Items Here, Get Info and every folder command
    of the pane itself (Open in Terminal, Add to Sidebar) are off, and a drop on the listing's
    background or on the server's sidebar row is refused, as Finder refuses them: a server has no
    folder to put an item in. On a share row: Open, Open in Other Pane, Quick Look, Get Info,
    Copy and a drop onto it act on the share's mount point as on any folder; Move to Trash,
    Cut, Duplicate and Rename are off, as Finder can't trash or rename a share; the context menu
    has `Eject “music”`, which ejects that share as the sidebar does. Copy and Move to Other Pane
    into a pane at a server are off. In column view 0111's rule stands: with a share selected
    alone in the server's column and its column shown, New Folder and Paste act in the share.
  - Go to Folder and the palette's paths: a relative path typed at a server starts at
    `/Volumes`, the folder its shares are in, so `music` goes to `/Volumes/music`.
  - History, Back and Forward keep server entries as any other; Back to a server selects the
    share left. ⌘U's positions ([0112](0112-position-history.md)) name a server's column as
    they name a folder's. Column widths are kept for a server's column by the server.
  - Window and tab titles show the server's name. A new tab, window or split of a pane at a
    server shows the server.
  - ⌘K's folder list ([0087](0087-palette-window.md)) leaves servers out: `FolderVisits`
    doesn't count a visit to one, and the panes' folders it adds skip them. It lists folders
    to type the path of; a server is reached from the sidebar, the path bar and Back.
- **Column view.** The server is a column, its rows the shares. A pane at the server shows that
  one column; selecting a share opens the share's column right of it. A folder in a share starts
  its trail at the server: `ColumnTrail.root(of:mountedVolumes:home:)` answers the share's
  server when the deepest volume holding the path has one, and the trail's columns are the
  server, then the folders from the share's mount point down (`ColumnTrail.chain(from:to:)`,
  `[server] + location.ancestors.dropFirst(2)` since a share is always at `/Volumes/<name>`).
  ← in the server's column does nothing, as at any root.
- **No column moves after the first frame.** 0103 takes a trail's first root from the path alone
  and checks it off the main thread; an added server column would move every share's columns
  after their first frame. So the first root reads the app's `MountTable` (main actor, read at
  launch and after each mount event, no file-system call on the main thread), which
  `ListingService` keeps as it keeps `recentListings`, so every pane reaches it. The launch's
  restore waits for its first read with the session's read ([0081](0081-restored-network-panes.md)).
  The off-main root check stays and corrects a trail built before a share mounted.
- **Path bar and Enclosing Folder.** `Pane.ancestors` is the one answer for both: the trail's
  chain from the server for a folder in a share, `location.ancestors` from `/` otherwise. A
  share's bar reads "HAL9000 › music › …", as Finder's does; the server segment is titled by its
  name, and a click on it shows the server with the share selected, a Cmd-click opens it in a
  new tab (0026). Enclosing Folder goes to the element before the pane's location, so ⌘↑ at a
  share's root shows the server with the share selected, and at the server does nothing, as
  Finder has no Network to go up to here. Disks keep 0026's bar from `/`.
- **Saved session: one shape.** A stored location is a `path` or a `server` (the host as the
  mount source writes it), never both: `TabState`'s panes, history entries and column widths
  write `"path"` for a folder exactly as now, so stored folders decode unchanged, and
  `"server"` for a server. One with both or neither is rejected with the workspace, as other
  undecodable data is. A server restored while not connected shows the not-connected state.
- **Sidebar.** `SidebarVolumes` lists a row per server where its first share is in the mount
  table's order, and no row for the server's shares. The row has the server's name, the
  `SidebarGenericFile` glyph (with 0108's SF Symbol stand-in until read), and 0108's eject
  button and context menu item, `Eject “HAL9000”`. A click or Return shows the server in the
  focused pane. The row stays selected while the pane goes into a share, as a favorite's row
  does now; the selection is kept across reloads by the server, as a volume row's is by its
  mount point. 0089's key routing is unchanged.
- **Ejecting a server** runs 0108's eject for each of its shares at once, each with its
  `willEject` and its one-at-a-time rule; the row's button is off while any of them runs. A
  refused share stays mounted and the others go, as in Finder. One sheet reports the refusals:
  0108's "The disk “main” wasn’t ejected." for one, "The disks “main” and “music” weren’t
  ejected." for more, with each system reason on its own line under it. The row leaves when its
  last share does.
- **Accessibility.** The server row reads as its name, with its eject button labeled as a volume
  row's is; the path bar's server segment reads as the server's name; a share row reads as its
  name with Kind "Volume"; the not-connected message is the pane's failure text, which
  VoiceOver reads as a folder's failure.

## Build steps

Each step lands with its tests; each test fails without the step.

1. **SB.7a, servers from the mount table** (Browser). `Server` (host, name, case-free
   equality), `VolumeIdentity.server`. Files: `Sources/Browser/Server.swift`,
   `VolumeIdentity.swift`; `Tests/BrowserTests/ServerTests.swift`, `VolumeIdentityTests.swift`.
   Tests: each source form, an IP host, `\032` and `\.` escapes, a share outside `/Volumes`,
   a local disk and a `MNT_DONTBROWSE` share give no server, two users on one host are one.
2. **SB.7b, `Location.server`** (Browser, Interface, app; mechanical). The enum, `path: String?`,
   every user deciding as above, but no way to reach a server yet besides tests: commands off,
   drops refused, FS users that can't receive one say so, `FolderVisits` skip, titles,
   `TabState`'s stored shape. Files: `Location.swift` and the users the compiler lists
   (`rg -l '\bLocation\b' Sources`). Tests: `LocationTests` (name, parent, ancestors, child of
   a server), `TabStateTests` (round trip of a server pane, history and width; a folder file
   from before decodes; both or neither keys rejected), `FileCommands`/`ClipboardCommands`
   tests for each command off at a server.
3. **SB.7c, a server's listing in list view** (Browser, Interface). `ListingService.load` of a
   server, no monitor, sizes or cache, `VolumeEvents` reload, not-connected state, share rows'
   icon, Kind and `--`, the share row's Eject item. Files: `ListingService.swift`, `Pane.swift`,
   `VolumeEvents.swift`, `ListingViewController.swift`, `EntryCellFormatter.swift`,
   `TypeIconCache.swift`, `ContextMenuBuilder.swift`. Tests: a stub mount table lists the
   server's shares and not others; a mount and an unmount event relist; no share gives the
   not-connected state and a mount brings rows; no monitor or walk starts; the views show the
   icon, "Volume" and `--`.
4. **SB.7d, trail and path bar** (Browser, Interface, app). `root` answering a server,
   `ColumnTrail.chain`, `MountTable` on `ListingService` for the first root, the restore
   waiting for its read, `Pane.ancestors`, Enclosing Folder, the path bar's server segment,
   the server's column in column view. Files: `ColumnTrail.swift`, `Pane.swift`,
   `ListingService.swift`, `MountTable.swift`, `PathBarView.swift`, `PaneViewController.swift`,
   `ColumnViewController.swift`, `WorkspaceWindows.swift`, `main.swift`. Tests: a share folder's
   trail starts at the server on its first frame with a read table, and is corrected by the
   check without one; a pane at the server has one column; ⌘↑ from a share root and at the
   server; the bar's segments and clicks; Back across server and share.
5. **SB.7e, the sidebar's server row** (Browser, Interface). Grouping in `SidebarVolumes`,
   `ejectServer`, the row, its glyph, click, selection kept by server, the refusal sheet.
   Files: `SidebarVolume.swift`, `SidebarVolumes.swift`, `SidebarIcons.swift`,
   `WorkspaceSidebarViewController.swift`. Tests: two shares give one row at the first share's
   place and no share rows; eject unmounts both with `willEject` for each; one refusal, two
   refusals and their sheet text; the button is off while any runs; a click shows the server;
   the row stays selected after a reload.

SB.7d and SB.7e touch different files after SB.7c and can run at once.

## Alternatives considered

- **A synthetic path for a server,** such as `/Volumes` or `//HAL9000` — rejected: every file
  system user would take it for a folder and do something wrong without a word. New Folder or
  Paste at `/Volumes` writes there, a monitor or size walk of `//HAL9000` fails as a missing
  folder. With a second case the compiler lists each user, and each refusal is written down.
- **A `Place` type above `Location`,** `Location` staying a path — rejected: the pane's
  location, history, positions, widths and stored state would all change type anyway, and the
  file system users would still reach the folder through an optional, so it moves the same
  sites and adds a type.
- **Listing a server's unmounted shares,** as Finder does — not done: it needs network browsing
  (`NetFS` or SMB share enumeration), which the app has none of, and a read of the server.
- **An optional `DirectoryEntry.modified`** for the shares' `--` — rejected: 39 users change for
  one listing whose views already know it is a server's.
- **Grouping shares mounted anywhere** — rejected for now: a server's shares then need a lookup
  to find their folders, where `/Volumes/<name>` needs none. The system mounts shares there.
- **Keeping the path bar at `/` for shares** ("Macintosh HD › Volumes › music") — rejected:
  Dylan asked for the server as a place in the path bar, and Finder roots a share's bar there.

## Consequences

A server reaches every place a folder does, and the compiler names each. Shares mounted outside
`/Volumes` or from a source that doesn't parse keep 0108's rows. One host reached two ways, by
its Bonjour name and by address, is two servers. The server glyph is always the generic file,
where Finder picks one from the server's advertised model. A pane at a server whose shares are
all gone shows it not connected, where Finder would list the unmounted shares. Disks keep 0026's
path bar from `/`, so a share's bar and a disk's differ. Not yet checked in Finder, and checked
by hand before SB.7c and SB.7d: a share's path bar segments, ⌘↑ from a share's root, and the
Kind, Size and Date Modified Finder shows for a server's shares.
