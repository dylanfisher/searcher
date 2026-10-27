# 0114. A connected server is a place: one sidebar row, its shares as its rows

- **Date:** 2026-10-26
- **Status:** proposed
- **Amends:** [0108](0108-sidebar-locations.md): "A share is listed by its mount point";
  [0026](0026-path-bar.md): "Which volume", for folders on a share;
  [0103](0103-column-trail-from-the-root.md): the trail's first column, for folders on a share.

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

Claims about Finder marked *(unverified)* below weren't checked in Finder; each is checked by
hand before the step that builds it.

## Decision

- **Which shares make a server.** A volume belongs to a server when it is a browsable network
  volume mounted directly in `/Volumes`, where the system mounts shares, and its source names a
  host: `//[user@]host[:port]/share` (SMB, AFP), `scheme://[user@]host[:port]/…` (WebDAV) or
  `host:/path` (NFS). `VolumeIdentity.server` gives it, with no read. A server is keyed by its
  full host as the source writes it, compared without case, so shares mounted by different users
  from one host are one server. The stored host keeps its spelling; only the comparison folds
  case. The name shown is the Bonjour instance name when the host is
  `<instance>._<service>._tcp.<domain>`, with `\DDD`, `\c` and percent escapes undone
  ("HAL9000"), and the host as written otherwise ("192.168.1.5"). Two keys can show one name:
  the same instance in two domains, or over SMB and AFP, are two servers both named "HAL9000".
  Shares mounted outside `/Volumes`, or whose source doesn't parse, keep their own rows as 0108
  has them (Dylan confirmed 2026-10-26).
- **The model: `Location` gets a second case.** `enum Location { case folder(path: String),
  case server(Server) }`, keeping `init(path:)`. `Server` holds the host and gives the name.
  `name` is the server's name, `parent` is nil, `ancestors` is `[self]`, and `child(named:)` is
  `/Volumes/<name>`, since a server's shares are the folders it has in `/Volumes`. `Location`
  stays a value with no read: a server's shares come from its listing, not from the location.
- **How a user gets a path.** Two accessors replace `path: String`:
  - `folderPath: String` traps with "a server has no folder path". The users that never
    receive a server use it: everything that touches the file system (loads of a folder,
    `FolderMonitor`, size walks, `ListingCache`, `RecentListings`, `FileOperation`s, Quick Look,
    Open, rename), and Interface code reached only from a folder pane.
  - `path: String?`, nil for a server, for the users that must decide: the saved session,
    `VolumeEvents`, `FolderVisits`, Go to Folder's base and titles. They switch on the case.
  - No `?? ""` and no silent return on a nil path: a user either traps through `folderPath` or
    handles `.server` by name.
  - **One rule for "off at a server":** `Location.isFolder`, false for a server. Every command
    and drop that is off at a server reads it, and nothing else decides it.
- **Each user of a location.**

  | User | At a server | Step |
  |---|---|---|
  | `ListingService.load` | Builds the listing from the app's `MountTable` (below), asking no share: one `.directory` entry per share, named by its mount point's last component as 0108 names a share ("main 1" for a second mount). No volume slot, stall timer or cache; hands `full`, or `notConnected` with no share mounted. | 7c |
  | `Pane` | No folder monitor, size walk, recent listing or cache. Lists again each time the `MountTable` reports a read that changed (below). | 7c |
  | List and column rows | CoreTypes' `GenericSharepoint` icon (read as `CoreTypesIcons` reads sidebar glyphs), Kind "Volume", `--` for Size and Date Modified *(unverified)*. Entries carry the Unix epoch as their date, which no view shows, so a date sort keeps name order. | 7c |
  | New Folder, Paste, Move Items Here, Get Info / Open in Terminal / Add to Sidebar of the pane's folder, Copy and Move to Other Pane into it | Off (`isFolder`), as Finder has no folder to put an item in. In column view 0111's rule stands: with a share selected alone and its column shown, New Folder and Paste act in the share. | 7b2 |
  | Move to Trash, Cut, Duplicate, Rename of a selected share | Off (`isFolder` of the pane's location), as Finder can't trash or rename a share *(unverified)*. Open, Open in Other Pane, Quick Look, Get Info and Copy act on the mount point as on any folder. | 7b2 |
  | Context menu of a share row | Adds `Eject “music”`, which ejects that share as the sidebar does. | 7c |
  | Drops | On the listing's background or the server's sidebar row: refused (`isFolder`). On a share row: `DropOperation` gets `pane.location.child(named:)`, the share's mount point, as for any folder row. | 7b2 |
  | Go to Folder, the palette's paths | A relative path typed at a server starts at `/Volumes`, so `music` goes to `/Volumes/music`. | 7b2 |
  | `History`, Back, Forward | Server entries as any other; Back to a server selects the share left. | 7b1 |
  | `SelectionHistory` (⌘U) | Positions name a server's column as a folder's. | 7b1 |
  | `ColumnWidths` | A server's column width is kept by the server. | 7b1 |
  | `FolderVisits`, ⌘K | Servers aren't counted (Dylan confirmed 2026-10-26). `FolderHistory` takes and stores folder paths only, so a server can't enter it; `FolderVisits.visit` skips `.server`, and `FolderSource` skips panes at one. | 7b2 |
  | Window and tab titles | The server's name. | 7b2 |
  | New tab, window, split | Shows the server, as the pane did. | 7b1 |
  | `TabState` | See "Saved session". | 7b2 |
  | `VolumeEvents` | A pane at a server isn't on any volume; its reloads come from the `MountTable`. | 7c |

- **One source of mount data.** The app has one `MountTable` (main actor, read off the main
  thread at launch and after each mount event, `MNT_NOWAIT`). `main.swift` makes it and passes it
  to `ListingService(mounts:)` and to `WorkspaceWindows`, which today makes its own
  (`WorkspaceWindows.swift:100`); no second `MountTable()` is made, since each one registers with
  `VolumeEvents`. Panes reach it as `service.mounts`, as they reach `recentListings`. The table
  gains `volumes`, `server(holding:)`, an `observe(for:_:)` that runs after a read that changed
  what it lists, and `firstRead()`, which returns once a read has landed. Both the server listing
  and the trail's server column read it, so they agree. A server pane lists on the table's
  observer, not on the raw mount event, so it never reads a table older than the event. A
  service without a table, as a bench makes, traps on a server load. The first read can't hang:
  `getmntinfo` with `MNT_NOWAIT` asks no volume.
- **Not connected** is a new `ListingState.notConnected`, used for a server with no share in the
  table: after all its shares are ejected or unmounted, and for a server restored before its
  shares mount. The pane shows "“HAL9000” isn't connected." where a folder's failure shows and
  stays there (Dylan confirmed 2026-10-26; Finder would list the unmounted shares, which needs
  network browsing the app doesn't have). It lists again when a read of the table holds one of
  its shares. Panes inside a share that unmounts go offline as [0049](0049-volume-events.md)
  says.
- **Column view.** The server is a column, its rows the shares. A pane at a server shows that
  one column; selecting a share opens the share's column right of it. A trail carries
  `serverRoot: Server?`, and when set, a column for the server comes before its first column.
  `root(of:mountedVolumes:home:)` is unchanged and still returns the share's mount point, so
  root, depth, folding, the waiting columns and the home rule are untouched; the server column is
  a prefix. A trail for a folder in a share sets `serverRoot` from `service.mounts` when it is
  built. A pane at the server itself has a trail of the server column alone, and `root` isn't
  asked. ← in the server column does nothing, as at any root.
- **The server column and the first frame.** A trail built while the table is unread, or before
  the share mounted, has no server column. When a later read gives the share a server, the
  trail adds the server column on the left: a move of the columns, but only in that window,
  which the restore closes by waiting for `firstRead()` within its existing 300 ms cap
  (`cachedRowsLimit`, [0081](0081-restored-network-panes.md)); past the cap the windows show and
  the column comes when the read lands. A share mounted later than its trail was built adds the
  column then. A server whose last share goes leaves its column, showing `notConnected`.
- **Path bar and Enclosing Folder.** `Pane.ancestors` is the one answer for both: for a folder
  in a share with a server, the server, then the folders from the share's mount point down;
  otherwise `location.ancestors` from `/`. A share's bar reads "HAL9000 › music › …"
  *(unverified)*; the server segment is titled by its name, a click shows the server with the
  share selected, and a Cmd-click opens it in a new tab (0026). Enclosing Folder goes to the
  element before the pane's location, so ⌘↑ at a share's root shows the server with the share
  selected *(unverified)*, and at the server does nothing. Disks keep 0026's bar from `/`
  (Dylan confirmed 2026-10-26; a volume-rooted bar is a later step).
- **Saved session: one shape.** A stored location is a `"path"` or a `"server"` (the host as
  written), never both: `TabState`'s panes, history entries and column widths write `"path"` for
  a folder exactly as now, so stored folders decode unchanged. A location with both keys or
  neither rejects the whole workspace, as other undecodable data does. A server restored while
  not connected shows `notConnected`. Until 7e nothing can put a pane at a server outside
  tests, so no session holds one before then: 7b2's shape is tested but dormant.
- **Sidebar.** `SidebarVolumes` lists a row per server where its first share is in the mount
  table's order, and no row for the server's shares. The row has the server's name, the
  `SidebarGenericFile` glyph (with 0108's SF Symbol stand-in until read), and 0108's eject
  button and context menu item, `Eject “HAL9000”`. A click or Return shows the server in the
  focused pane. The row stays selected while the pane goes into a share, as a favorite's row
  does now; the selection is kept across reloads by the server, as a volume row's is by its
  mount point. 0089's key routing is unchanged. The sidebar keeps 0108's own read, which asks
  local volumes for their names; its server rows and a server listing can differ for the moment
  between the two reads after an event.
- **Ejecting a server** runs 0108's eject for each of its shares at once, each with its
  `willEject` and its one-at-a-time rule; the row's button is off while any of them runs. A
  refused share stays mounted and the others go *(unverified)*. One sheet reports the refusals:
  0108's "The disk “main” wasn’t ejected." for one, "The disks “main” and “music” weren’t
  ejected." for more, with each system reason on its own line under it. The row leaves when its
  last share does.
- **Accessibility.** The server row reads as its name, with its eject button labeled as a volume
  row's is; the path bar's server segment reads as the server's name; a share row reads as its
  name with Kind "Volume"; the not-connected message reads as a folder's failure does.

## Build steps

In order; each step lands with its tests, and each test fails without the step.

1. **SB.7a, servers from the mount table** (Browser). `Server` (host, name, case-free
   equality), `VolumeIdentity.server`. Files: `Sources/Browser/Server.swift`,
   `VolumeIdentity.swift`; `ServerTests.swift`, `VolumeIdentityTests.swift`. Tests: each source
   form, an IP host, `\032` and `\.` escapes, one instance in two domains gives two servers with
   one name, a share outside `/Volumes`, a local disk and a `MNT_DONTBROWSE` share give none, two
   users on one host are one, a host's spelling is kept.
2. **SB.7b1, the enum** (every tier, Bench and `UIBench` included; no behavior change). The
   enum, `folderPath`, `path: String?`, `isFolder`, the server answers of `name`, `parent`,
   `ancestors` and `child(named:)`; every user the compiler lists moves to `folderPath` or
   switches on the case. Files: `Location.swift` and `rg -l '\bLocation\b' Sources`. Tests:
   `LocationTests` for each server answer and `folderPath` of a folder; `HistoryTests` and
   `SelectionHistoryTests` keep server entries.
3. **SB.7b2, what a server turns off** (Browser, Interface). `TabState`'s stored shape, the
   commands and drops off by `isFolder`, Go to Folder's base, `FolderHistory` by folder path and
   `FolderVisits` skipping servers, titles. Files: `TabState.swift`, `FileCommands.swift`,
   `ClipboardCommands.swift`, `DualPaneCommands.swift`, `SystemCommands.swift`,
   `PathInput.swift`, `FolderHistory.swift`, `FolderVisits.swift`, `FolderSource.swift`,
   `ListingViewController.swift`, `ColumnViewController.swift`, `BrowserWindowController.swift`.
   Tests: a server pane, history and width round-trip with the host's spelling; a folder file
   from before decodes; both keys and neither key each reject the whole workspace; each command
   off at a server and on for a share's column under 0111; a background drop refused; a visit
   to a server leaves `FolderHistory` unchanged.
4. **SB.7c, a server's listing** (Browser, Interface, app). The one `MountTable` made in
   `main.swift` and injected, its `volumes`, `server(holding:)`, `observe` and `firstRead`;
   `ListingService.load` of a server, `notConnected`, no monitor, sizes or cache, relisting on the
   table's observer; rows' icon, Kind and `--`; a share row's Eject. Files: `MountTable.swift`,
   `ListingService.swift`, `ListingState.swift`, `Pane.swift`, `main.swift`,
   `WorkspaceWindows.swift`, `ListingViewController.swift`, `EntryCellFormatter.swift`,
   `TypeIconCache.swift`, `ContextMenuBuilder.swift`, `PaneViewController.swift`. Tests: a stub
   table lists the server's shares and no others; a changed read relists and an unchanged one
   doesn't; no share gives `notConnected` and a read with one gives rows; no monitor or walk
   starts; the views show the icon, "Volume" and `--`; Back to a server that has since lost its
   shares shows `notConnected` without a trap. A share opened from this listing has the 0103
   trail and the bar from `/` until 7d; a server is reached only from tests and a restored
   session until 7e.
5. **SB.7d, trail and path bar** (Browser, Interface). `serverRoot` and the prefix column,
   adding it when a read gives the share a server, the restore's wait for `firstRead()`,
   `Pane.ancestors`, Enclosing Folder, the path bar's server segment. Files: `ColumnTrail.swift`,
   `Pane.swift`, `PathBarView.swift`, `ColumnViewController.swift`, `WorkspaceWindows.swift`.
   Tests: with the table read, a share folder's trail has the server column on its first frame;
   unread, it has none and the read adds it; a pane at the server has one column; ⌘↑ from a
   share root and at the server; the bar's segments and clicks; Back across server and share;
   ⌘U to a step in the server column after the server lost its shares restores the column,
   shows `notConnected` and drops the names as 0077 does; Undo of a paste and of a move inside
   a share, with the server as the first column, acts on the record's paths and leaves the
   server column as it was.
6. **SB.7e, the sidebar's server row** (Browser, Interface). Grouping in `SidebarVolumes`,
   `ejectServer`, the row, its glyph, click, selection kept by server, the refusal sheet. Files:
   `SidebarVolume.swift`, `SidebarVolumes.swift`, `SidebarIcons.swift`,
   `WorkspaceSidebarViewController.swift`. Tests: two shares give one row at the first share's
   place and no share rows; eject unmounts both with `willEject` for each; one refusal, two
   refusals and their sheet text; the button is off while any runs; a click shows the server;
   the row stays selected after a reload.

7d and 7e share no file and can run at once after 7c. If either finds it needs a file of the
other, 7d goes first.

## Alternatives considered

- **A synthetic path for a server,** such as `/Volumes` or `//HAL9000` — rejected: every file
  system user would take it for a folder and do something wrong without a word. New Folder or
  Paste at `/Volumes` writes there, a monitor or size walk of `//HAL9000` fails as a missing
  folder. With a second case the compiler lists each user, and each refusal is written down.
- **A `Place` type above `Location`,** `Location` staying a path — rejected: the pane's
  location, history, positions, widths and stored state would all change type anyway, and the
  file system users would still reach the folder through an optional, so it moves the same
  sites and adds a type.
- **`root(of:)` returning the server** — rejected: root, depth, folding and the home rule all
  work on a path; a prefix column leaves them as they are.
- **A second mount read for the server listing,** `ListingService`'s own `mountedVolumes` —
  rejected: the listing and the trail's server column could disagree after an event. The
  0103 root check keeps its own read, since it decides nothing about servers.
- **Listing a server's unmounted shares,** as Finder does — not done: it needs network browsing
  (`NetFS` or SMB share enumeration), which the app has none of, and a read of the server.
- **An optional `DirectoryEntry.modified`** for the shares' `--` — rejected: 39 users change for
  one listing whose views already know it is a server's.
- **Grouping shares mounted anywhere** — rejected for now: a server's shares then need a lookup
  to find their folders, where `/Volumes/<name>` needs none. The system mounts shares there.
- **Keeping the path bar at `/` for shares** ("Macintosh HD › Volumes › music") — rejected:
  Dylan asked for the server as a place in the path bar.

## Consequences

A server reaches every place a folder does, and the compiler names each. Shares mounted outside
`/Volumes` or from a source that doesn't parse keep 0108's rows. One host reached two ways, by
its Bonjour name and by address, is two servers, and one instance in two domains is two rows
with one name. The server glyph is always the generic file, where Finder picks one from the
server's advertised model. A pane at a server whose shares are all gone shows it not connected,
where Finder would list the unmounted shares. Disks keep 0026's path bar from `/`, so a share's
bar and a disk's differ. A server column can appear left of a trail built before the mount
table's first read or before its share mounted. ⌘K doesn't list servers.
