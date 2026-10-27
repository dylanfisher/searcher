# 0115. A server lists the shares it offers, and opening an unmounted one mounts it

- **Date:** 2026-10-26
- **Status:** proposed
- **Amends:** [0114](0114-server-location.md): the server listing, built from the `MountTable`
  alone, and its rejected alternative "Listing a server's unmounted shares".

## Context

Dylan, 2026-10-26: "hal9000 and other volumns need to show any unmounted disks inside them, like
finder does (we can only see music right now)". Finder's column for HAL9000 (screenshot
`tmp/shots/finder-server-unmounted-shares.jpg`) shows a header card (server icon, "HAL9000",
"Connected as: dylan", a Disconnect button) over seven shares, docker, home, homes, main, music,
NetBackup and video, each with the shared-folder icon and a chevron. Only music, the one mounted,
has an eject button. The status bar says "7 items".

What this machine shows, read-only, with music mounted from `//dylan@HAL9000._smb._tcp.local`:

- `smbutil view -N //dylan@HAL9000._smb._tcp.local` lists eight shares in 0.07 s, with no
  prompt. Its text is a `Share` header padded to column 48 then `Type` and `Comments`, a line of
  31 dashes, one row per share in the server's order, a blank line, and `8 shares listed`. Seven
  rows are type `Disk`; `IPC$` is `Pipe` with the comment `IPC Service ()`. `-N` is "don't
  prompt for a password". It exits 0; a wrong user exits 77 with "server rejected the
  authentication" on stderr. Against an address with nothing there it blocked 60 s ("Operation
  timed out"), so it needs the bound below.
- The public NetFS headers offer `NetFSMountURLSync`, `NetFSMountURLAsync`, `NetFSMountURLCancel`
  and no call that lists shares. `EnumerateShares` is in `NetFSPlugin.h`, the interface the
  protocol bundles implement. A mount of a bare server URL opens the system's share picker.
  `SMBClient.framework` is private, with no header in the SDK.
- NetFS.h on cancel: "The NetFSMountURLBlock is not submitted if the request is cancelled"
  (and "not called" at `NetFSMountURLCancel`). The
  header doesn't say whether the block runs after a non-zero return from `NetFSMountURLAsync`;
  the code treats that status as final and expects no block. Both shape the state machine below.
- `kNetFSIsHiddenKey` (`IsHidden`) is defined in NetFS.h for the plugin's share dictionary.
  `smbutil`'s text doesn't carry it, so the `$` rule below is this record's own.
- Bonjour (`_smb._tcp`) names a server and gives its address, never its shares.

Claims about Finder or the system marked *(unverified)* weren't checked; each is checked by hand
before the step that builds it, and the list is under "For Dylan to check".

## Decision

- **Confirmed by Dylan, 2026-10-26.** (1) Linking `NetFS` and running `/usr/bin/smbutil` are
  accepted under the dependency rule: both are parts of the system. (2) The header card is
  later, not in the steps below. (3) AFP, NFS and WebDAV servers list their mounted shares only,
  with a notice that the others can't be listed.
- **Enumeration: `smbutil view -N`, for SMB.** A documented system tool (`smbutil(1)`) that
  reuses the session a mounted share holds. Public API has no enumeration, so the choice is a
  subprocess, the private framework, or the plugin interface. The private framework has no
  header or support promise; loading a protocol bundle by hand has the same risk with more code;
  speaking SMB2 ourselves is a new protocol stack. The cost of the subprocess is its text,
  which fixtures pin.
- **The request is a server and a user.** `Server` is host-only, so two users on one host are
  one server (0114) and the enumeration must say which. `ShareRequest` is `(Server, user)`:
  `user` is the user of the first mounted SMB share of that server in the mount table's order,
  from its source, percent-decoded, `DOMAIN;user` kept whole; nil for a source with no user. The
  command is `smbutil view -N //<user>@<host>` with that user percent-encoded for a URL
  (`;` kept) and the host as the source writes it, built with `URLComponents` percent-encoded
  fields so nothing is encoded twice. *(8a)* The user is encoded once with `urlUserAllowed` less
  `:`, which `URLComponents` keeps and `smbutil` reads as the start of a password; the host is
  appended as written and not passed through `URLComponents`, which would check it as a URL host
  and a Bonjour name with `\032` isn't one; an IPv6 address gets its brackets back (AU.7). It
  runs with no shell, `LC_ALL=en_US.UTF-8`, and no user means `//<host>`. A second user's shares on that host are listed as that user sees them: a
  share only the first user can see is not shown unmounted. If the first mount goes and another
  user's remains, the request changes and the cache (below) misses.
- **A server needs a mounted share to be listed,** as 0114 has it. A server with none is
  `notConnected`, and its cache entries (every user) are dropped. Whether `smbutil -N` works from
  the keychain alone is *(unverified)* and not relied on.
- **Which names.** Only type `Disk` and no name ending in `$`: this drops `IPC$`, printers and
  administrative shares. Finder's 7 items for the 8 listed confirm `IPC$` is dropped; whether it
  hides a disk share such as `C$` is *(unverified)*. A mounted share is listed whatever its name.
- **Parsing is strict and not by column.** The header line must start with `Share` and contain
  `Type` and `Comments`; the next line is dashes only; rows follow to the blank line; the
  trailer is `<n> share(s) listed` and `n` must equal the row count. A row's name is everything
  before the first run of two or more spaces followed by a known type token (`Disk`, `Pipe`,
  `Printer`, `Comm`) and a space or the line's end; comments are free text and ignored. A name
  of 48 or more characters (no padding), a name with a single space or a double space, and a
  Unicode name parse. *(8a)* `smbutil`'s format is `%-48s%-8s%s`, which pads by bytes: a name of
  47 bytes is followed by one space and a longer one by none, so those two splits are also taken
  for a name of exactly 47 bytes and of 48 or more. A name that itself contains two spaces and a type token cannot be told from
  the columns; it parses wrongly and is accepted as a residual. Output is decoded as UTF-8
  strictly. A missing header, a bad count, a type outside the known set, or invalid UTF-8 throws
  `ShareListError.unparsable`, so a format change shows as a notice and not as a wrong list. The
  known set is from `smbutil`'s own output: `Disk` and `Pipe` are seen, `Printer` and `Comm` are
  *(unverified)*.
- **The mounted share's name.** A mounted share's name for matching is the last component of its
  source, percent-decoded with `removingPercentEncoding`. Names compare by canonical
  (NFC) form and case folding, since SMB share names are case-insensitive and macOS may hand NFD.
  A source that doesn't decode, or decodes to an empty name or one with a `/` (`%2F`), has no
  share name: the enumeration is not run for its server and the pane shows the notice "Couldn't
  match the shares mounted from “HAL9000”." with the mounted rows. Nothing traps. How the system
  writes a space, a Unicode name or `%` in `f_mntfromname` is *(unverified)*, as is how it writes
  a `DOMAIN;user` and a Bonjour host with `\032` for a space; both are checked by hand against
  a real share with a space in its name (8c, 8d).
- **What the other protocols get.** AFP, NFS and WebDAV servers list their mounted shares only,
  and the pane's notice says: "Only mounted shares are listed for AFP servers." Nothing public
  lists AFP shares, `showmount` covers NFSv3 exports only, and a WebDAV URL is one share.
  `VolumeIdentity` gains `fsType` (`f_fstypename`, already in the `statfs` read with
  `MNT_NOWAIT`) to tell `smbfs` from `afpfs`, `nfs` and `webdav`. *(8a)* Since it is part of the
  identity, `ListingCacheStore` stores it with each volume, so a volume read back from its file
  equals the mounted one it was saved for. A server with shares of two
  protocols gets the SMB enumeration, no protocol notice, and its other shares stay as mounted.
  *(8c)* A file system none of these is named in the notice by its `f_fstypename`.
- **Where it runs.** Under [0038](0038-slow-volumes.md): the subprocess is started and waited on
  from `BlockingCallThread`s, `requireCurrent` checked first. `ServerShares` holds, per
  `ShareRequest`, one enumeration in flight; a second asker joins it. Time comes from the
  injected `Clock`. Nothing in this record runs on the main actor except the state it updates.
- **The subprocess, exactly.** `Process` with stdin `/dev/null`; stdout and stderr each drained
  to the end on a thread of their own (a full pipe would stall it), stdout capped at 1 MB
  (more is `unparsable`); the end is waited on with a semaphore the `terminationHandler`
  signals, not `waitUntilExit`, which runs the run loop. At `LoadTimeouts.giveUp` (30 s) a
  clock task calls `terminate()`; if it is still running 2 s later it is killed, and either way
  the semaphore is waited on so the process is reaped, never left a zombie. When the last asker
  of an enumeration is cancelled (its pane left the server), the process is terminated the same
  way. At app quit `ServerShares.stop()` terminates what is running, called from `main.swift`'s
  terminate path. A missing executable is `ShareListError.toolMissing`, not a trap.
- **Result and failure types.** `ShareListError` is `rejected` (exit 77), `unreachable` (give-up
  or timeout), `failed(String)` (any other exit, the first line of stderr), `unparsable`,
  `toolMissing`. It is its own type: `ListingError.reason` is switched exhaustively in many
  places and has no rejected-credentials case, so it stays as it is.
- **Cache and backoff.** `ServerShares` keeps the last result per `ShareRequest` with its time:
  names for 30 s; a failure for 10 s (`failureBackoff`), so a rejected password on a server
  whose table changes often doesn't start a process per change. A listing within those times
  starts no process. A load, a table change and the app becoming active all ask with the same
  call, so none of them has a rule of its own. Nothing polls and nothing is written to disk. A
  share added on the server shows at the first ask past 30 s. Finder updates a server's list live
  *(unverified)*. *(8c)* The app becoming active calls `ServerShares.relistServers()`, which
  panes at a server observe as they observe the mount table. `forget` lets a run in flight for
  that server answer its askers and keeps nothing it returns: ending it would leave a pane's
  load with no last update. `stop()` runs from `applicationWillTerminate`.
- **The listing.** `ListingService.loadServer` takes `mounts.volumes` of that server and the
  enumerated names, and lists one row per mounted share as 0114 has it (named by the mount
  point's last component, so "main 1" stays "main 1" and `/Volumes/<name>` is its mount point),
  plus one row per enumerated name no mounted share of the server has, matched by the key
  above. Several mounts of one share stay several rows and no unmounted row is added for it:
  Eject and open use the row's own mount. A mounted share the server didn't list stays.
  *(8c)* A listed name that is already a row's name, a share mounted at another share's
  folder name, adds no row, since `Listing` needs its names unique. `ListingService(shares:)`
  is optional: a service without it lists a server's mounted shares only, as the tests of the
  mount table alone make it; the app always passes one. A load asks `ServerShares` from a task
  that `ListingLoad.whenCancelled` cancels, so leaving the server lets go of the run.
- **The rows are typed so a wrong path is unreachable.** Naming rows by the share would let an
  unmounted "main" of HAL9000 resolve to `/Volumes/main`, which may be another server's mounted
  "main", and a drop would copy into it. So: `DirectoryEntry.FileType` gains `unmountedShare`
  (the compiler lists every exhaustive switch on it); `Location.child(named:)` is renamed
  `folderChild(named:)` and traps at a server as `folderPath` does, so the compiler lists the
  ~34 callers and each is decided: a folder-only caller keeps the new name, and a caller that can
  see a server's row uses `Pane.childLocation(of:)`. That is the one way from a row to a
  location: a folder joins the path; a server's mounted row asks `MountTable.mountPoint(
  ofRow:in:)`, which requires a mount point `/Volumes/<name>` whose volume's server equals the
  pane's server in the table's current read, and gives nil otherwise (the share was ejected, or
  another server mounted a folder of that name); an `unmountedShare` row gives nil. Every
  nil means "not mounted": the drop, open or eject is refused, never guessed. This replaces
  `ejectableShare(named:)` and the drop check in `ListingViewController`.
- **An unmounted share, until it is mounted** (from the step that first shows one).
  `GenericSharepoint` icon, Kind "Volume", `--` for Size and Date Modified, as a mounted share.
  Refused or off: dropping on it (drop validation reads `childLocation(of:)`), dragging it (no
  pasteboard writer, no URL), spring-loading, Eject, Copy Path, Reveal, Open With, Services and
  Share, Tags, Compress, Get Info, Quick Look, Copy, Cut, Duplicate, Rename, Move to Trash, Open
  in Other Pane, Open in Terminal, Add to Sidebar. A selection that includes one turns those
  off for the whole selection, read from one predicate, `Pane.selectsUnmountedShare`, and
  `ClipboardCommands.selectedURLs(in:)` leaves an unmounted row out as a second guard. New Folder,
  Paste and Move Items Here with one selected alone in column view act on 0111's destination:
  an unmounted share has no column, so it is the focused column's folder, the server, where
  they are off. Open is off until the mounting step. The context menu is Open, disabled.
  *(8c)* `selectsUnmountedShare` is true for any server row with no location, so a folder row
  whose share was ejected, or whose `/Volumes/<name>` another server now holds, counts too
  until the server lists again. `ClipboardCommands.selectedURLs(in:)` gives nil for such a
  selection rather than leave the row out, as `FileCommands` does, so Copy can't empty the
  clipboard and no command acts on part of a selection.
- **Notice and state.** Rows and a reason together need a state that carries both.
  `ListingState` gains `serverListed(Listing, ServerNotice)` and `ListingUpdate` the matching
  `serverListed(Listing, ServerNotice, rootVolumeName:)`; `ServerNotice` is `couldntList(
  ShareListError)`, `onlyMounted(ShareProtocol)`, or `unmatchedMounts`. `full` is kept for a
  listing with nothing to say. `serverListed` shows its rows as `loaded` does: `listing` returns
  them, `showsWholeFolder` is true, `showsCompleteListing` is false (a name not listed may be
  on the server), `isAnswered` is true, `listedAt` is nil, `showing(_:)` keeps the notice.
  Consumers touched, each switch exhaustive so the compiler lists them: `ListingState`
  (`listing`, `listedAt`, `showsCompleteListing`, `showsWholeFolder`, `isAnswered`, `showing`),
  `Pane` (the update handler, `show(_:after:)` and the switches at its lines ~811, 967, 1438,
  1465, 1515, 1543, 2056, 2438), `ColumnTrail` (~770, follow and first-row selection),
  `PathSource` (~80), `PaneStatusText.note`, `PaneStatusView` (`show`, `isInFlight`, and the
  switch at ~123), `PaneViewController.message(for:)` and `ColumnViewController.message(for:)`
  (~806): the last two show text only where there are no rows, so they return nil for it.
  The notice renders as the status view's note, the line that the slow and offline notes use
  under their rows, in list view and for the focused column in column view. In column view a
  server column that isn't focused (a share's column has the keys) shows no notice; it shows
  again when the keys come back. *(To be seen by hand.)* The text is
  "Couldn't list the shares on “HAL9000”: The server rejected the password." (`rejected`), "...:
  The server isn't answering." (`unreachable`), "...: <stderr line>" (`failed`), "...: The
  server's reply wasn't understood." (`unparsable`, `toolMissing`), and the protocol and
  unmatched-mount sentences above. An empty result with exit 0 lists the mounted shares and
  says nothing. The announcement for VoiceOver is the status view's.
- **Showing and refreshing.** A server load with no cache entry hands nothing until the
  enumeration returns (the pane shows `loading`, the spinner after
  `LoadTimeouts.spinnerDelay`), then `full` or `serverListed`. With a cache entry, of any age,
  it hands `cached(Listing, listedAt:)` at once (mounted rows plus the cached names) and then the
  final update, as a network folder does with `ListingCache`, so the pane shows
  `cachedRefreshing` while a stale entry is refreshed. At `LoadTimeouts.slow` (3 s) without a
  result it hands `slow`, named by the server, and at 30 s the process ends and the final update
  is `serverListed(.couldntList(.unreachable))`. A table change relists from the table and the
  cache and starts a process only if the entry is older than 30 s or absent.
- **Mounting: `NetFSMountURLAsync`.** The URL is built from a mounted SMB share's source (the
  same `ShareRequest` user, the same encoding rules, the share percent-encoded): `smb://<user>@
  <host>/<share>`; no file-system call, since `NetFSCopyURLForRemountingVolume` would `statfs`
  and 0038 keeps that off hung shares. `mountpath` is nil, so the system mounts under `/Volumes`
  and names the folder. `open_options` is `UIOption: AllowUI` (NetFS.h defines `NoUI`,
  `AllowUI` and `ForceUI`), so the system shows its sign-in window only if the session and
  keychain don't cover the share; `NoUI` would fail with no way to answer. Whether a second
  share of a session mounts with no prompt is *(unverified)*. `mount_options` is empty. Both
  dictionaries are `CFMutableDictionary`, which isn't `Sendable`, so they are built inside the
  call, on the thread that makes it, from a `Sendable` request value. A mount is started only for
  a mounted share's server, so a mounted SMB share is always there to take the user from.
- **The mount state machine.** `ShareMounts` (main actor) keeps one entry per mount key (server,
  user, share key). `ShareMounter` is a protocol shaped like NetFS: `start(request, completion)`
  returns `.failed(status)` for a non-zero immediate return, for which the completion never
  runs, or `.started(handle)`, whose completion runs once on a private serial queue unless
  `cancel(handle)` is called first; the fake in tests never calls the completion after a cancel.
  - **Start** (no entry): the entry is made with the asker as its only waiter, and `start` runs
    on a `BlockingCallThread`. `.failed(status)`: the entry completes at once with that status.
    `.started(handle)`: the handle is stored; if the last waiter left meanwhile, `cancel(handle)`
    runs now.
  - **Join** (an entry exists): the asker is added as a waiter. All waiters get one result.
  - **Cancel** (a waiter's task is cancelled: Escape, another row selected, the pane left the
    server, the tab or window closed): that waiter resumes with `cancelled` at once, by this
    code and not by a completion. When the last waiter has gone, `cancel(handle)` runs on a
    `BlockingCallThread` and the entry is removed. The mount may have finished in the kernel
    before the cancel; then the share is mounted and nothing navigates. That is intended: its row
    becomes mounted when the table reads it.
  - **Complete** (the completion hops to the main actor): an entry that is still there resumes
    every waiter with the status and the mount points and is removed; an entry that is gone
    (cancelled) ignores it.
  - A result arrives as `mounted(mountPoint)`, `alreadyMounted`, `cancelled`, or
    `failed(status)`. `EEXIST` (or `kNetFSAlreadyMounted`) is `alreadyMounted`: its mount point is
    the first of the completion's list, or, when that is empty, the mounted share of this
    server matching the share key in the table's current read; with none found it is a failure
    with `strerror`. Status -128 and a cancel are `cancelled` and show nothing.
- **What a successful mount does.** The pane isn't matched by server: a remount may record a
  different host than the row's. After a result the pane's table is read again
  (`MountTable.refreshed()`, which starts a read and returns once it has landed) and the mount
  point in the result is looked up in it. Found: a waiter still waiting goes there, in list view
  by navigating to the mount point, and in column view by selecting the row named by the mount
  point's last component, which follows at once as a click does. Not found: nothing navigates;
  the row appears with the next read. A waiter is "still at that server with that share
  selected" exactly while it hasn't been cancelled, and a waiter is cancelled by any change of
  the pane's location (Back, Forward, a path bar click, a new location), by a selection that
  isn't that one row, by Escape, and by the pane closing. So a mount finishing after the user
  moved on makes a mounted row and nothing else.
- **When a mount starts.** Only where a column would open, so holding ↓ through seven shares
  starts nothing on the six it passes. The delay is `ColumnTrail.openDelay` (120 ms,
  [0094](0094-column-open-delay.md)), not 0111's. In column view: a click on the row follows at
  once and starts the mount; a key-made selection starts it when the keys have paused for
  `openDelay`, which is when `follow` would open its column; → and ⌘↓ start it at once
  (`openHeldColumn`). Before that a selected unmounted share shows nothing extra. In list view:
  Return, ⌘↓, Open, double-click and → start it; a click or arrow selection only selects.
  Finder's behavior on a plain selection, whether it connects when a share is highlighted in
  column view and how it treats a key stopped on a share, is *(unverified)*. Because a stop of
  the arrow starts a mount, an unmounted share the keys stop on may show a sign-in window.
- **What a mount shows.** After `LoadTimeouts.spinnerDelay` (150 ms) the row shows a spinner and
  the status bar "Connecting to “main”…". A mount has no give-up time, since a sign-in window
  may be waiting for the user. A result other than `mounted`, `alreadyMounted` and `cancelled`
  shows a sheet as 0108's eject failure does: "The share “main” couldn’t be opened." with the
  reason under it, from `strerror` for a positive status and a short text for the NetAuth and
  `ENETFS…` codes in NetFS.h (password rejected, no shares available, no authentication method);
  an unknown code shows as "Error -6600." Escape cancels as above; Finder cancels the same way
  *(unverified)*.
- **Accessibility.** An unmounted share reads as its name with Kind "Volume" and "not mounted";
  the spinner is labeled "Connecting"; the notice reads as a slow or offline note does.
- **Dependency.** `import NetFS` links a system framework, as `IOKit` and `CoreServices` are
  today, and `/usr/bin/smbutil` is a tool the system ships. Dylan accepted both (above).
- **The header card is later** ("Connected as", Disconnect as 0114's eject of the whole server,
  scrolling with the rows in column view; list view has no place for it). It needs the same user
  `ShareRequest` carries, and no step here blocks it.

## Build steps

In order; each lands with its tests, and each test fails without the step. Tests of a path the
user can reach go through the real `ListingService`, panes, views and `MountTable`; fakes stand
in for disk, network and clock only, and `smbutil` and NetFS count as network. Waits are on
gates and `Settle` conditions, not sleeps: the enumerator and the mounter fakes signal when they
are entered, so a test holds a call open, acts, and releases it. 8a and 8b share no file and can
run at once; 8c needs both; 8d needs 8c. No step makes a wrong path reachable: 8b adds a case
nothing yet produces, and 8c, which first shows an unmounted row, ships its refusals.

1. **SB.8a, the share list** (Browser, Base). `ShareNames` (strict parser), `ShareListError`,
   `ShareRequest`, `ServerShares(enumerator:clock:)` with cache, backoff, join, askers, `stop()`,
   `SmbutilShares` (the runner, per "The subprocess, exactly"), `VolumeIdentity.fsType` in
   `==`, `hash` and so in `MountTable.land`'s changed check, and computed `share` and `user`;
   `StubMounts` and `mountedShare(_:of:user:fsType:)` gain the new fields; a gated enumerator in
   `TestSupport`. Files: `Sources/Browser/ShareNames.swift`, `ShareListError.swift`,
   `ServerShares.swift`, `SmbutilShares.swift`, `VolumeIdentity.swift`,
   `Sources/BrowserTestSupport/StubMounts.swift`; their tests. Tests: this machine's output
   as a fixture (eight rows, seven kept); a 48-character name, a Unicode name, a name with a
   double space, a `Printer` row, "0 shares listed" (hand-written fixture), a bad count, a missing
   header, an unknown type, invalid UTF-8 each throw or parse as stated; a source with a space,
   `%25`, NFD and `%2F` gives its share name or none; the same table with only `fsType` changed
   lands as changed; exit 77, a timeout, another exit and a missing tool each give their error;
   a second ask joins the first and a cancelled last asker terminates the run; a hit within 30 s,
   a miss after, a failure repeated within 10 s starts no process, all on `ManualClock`; the
   runner against a fake executable script that fills both pipes beyond the pipe buffer, hangs
   until terminated, and is reaped. Two users on one host make two requests.
2. **SB.8b, rows typed so no wrong path resolves** (Base, Browser, Interface; no visible
   change). `FileType.unmountedShare`, `folderChild(named:)` rename, `Pane.childLocation(of:)`,
   `MountTable.mountPoint(ofRow:in:)`, `ejectableShare` and the drop check moved onto it. Files:
   `DirectoryEntry.swift`, `Location.swift`, `MountTable.swift`, `Pane.swift`, `ColumnTrail.swift`,
   `ListingViewController.swift`, `ColumnViewController.swift`, and every file `rg
   'child\(named:'` lists. Tests: `childLocation` of a folder; of a server's mounted row; of a row
   whose `/Volumes/<name>` now belongs to another server's mount, nil; of a row after its share
   was ejected, nil; of an `unmountedShare` row, nil even with another server's "main" mounted
   at `/Volumes/main`; `child(named:)`'s old behavior at a server is a trap test.
3. **SB.8c, the share list in the pane** (Browser, Interface, app). `ListingService(shares:)`,
   the merge, `serverListed` and `ServerNotice` through the consumers listed, cached-then-final
   updates, slow, relist on the table's observer and on app activation (`main.swift`), the
   unmounted row's look and every refusal, Open disabled. Files: `ListingService.swift`,
   `ListingState.swift`, `ListingUpdate.swift`, `Pane.swift`, `ColumnTrail.swift`,
   `PathSource.swift`, `PaneStatusText.swift`, `PaneStatusView.swift`, `PaneViewController.swift`,
   `ColumnViewController.swift`, `ListingViewController.swift`, `ListingTableView.swift`,
   `SpringLoader.swift`, `ContextMenuBuilder.swift`, `EntryCellFormatter.swift`,
   `FileCommands.swift`,
   `ClipboardCommands.swift`, `SystemCommands.swift`, `DualPaneCommands.swift`, `main.swift`.
   Tests, in a window, with a stub table and a gated enumerator: one mounted share and an
   enumerator of three lists three rows, one with Eject, in list and column view; a share
   mounted later is mounted with no second row; two mounts of "main" are two rows and no
   unmounted "main"; a failing enumerator shows the mounted row and the notice with each
   reason, in list and for the focused column; AFP shows its notice; an undecodable source shows
   `unmatchedMounts`; a case-different name matches; a cached entry shows `cachedRefreshing`
   then the final rows; slow shows at 3 s on the clock; a table change inside 30 s starts no
   process; an unmounted "main" with another server's "main" at `/Volumes/main`: a drop on it is
   refused, nothing is copied, a drag from it has no URL, and each command in the list above is
   off, in both views; Back to a server that has lost its shares drops its cache entry. By hand:
   the notices' placement in both views.
4. **SB.8d, mounting** (Browser, Interface). `ShareMounter` and its `NetFS` implementation,
   `ShareMounts`, `MountTable.refreshed()`, the triggers, spinner and status text, the failure
   sheet, going into the mount point, Open enabled. Files: `ShareMounter.swift`,
   `NetFSShareMounter.swift`, `ShareMounts.swift`, `MountTable.swift`, `Pane.swift`,
   `ColumnTrail.swift`, `ListingViewController.swift`, `ColumnViewController.swift`,
   `FileCommands.swift`, `PaneViewController.swift`, `ContextMenuBuilder.swift`. Tests, in a
   window with the fake mounter: Return starts one mount and a second Return joins it; ↓ held
   through seven rows with the clock stopped starts none, and starting one after `openDelay`; a
   click in column view starts it at once, a click in list view does not; success goes into the
   mount point in list view and opens the share's column in column view, and not after Back, a
   path bar click, another selection, Escape or the pane closing; the table read not yet
   containing the mount point navigates nothing; an immediate non-zero return fails at once with
   no completion; cancel with no completion after it, from two panes, cancels the NetFS request
   only with the last; a completion after a cancel is ignored; `EEXIST` with an empty list finds
   the table's mount; a remount recorded under another host is still reached; the spinner shows
   only after 150 ms; the sheet text for a positive, a negative and an unknown status; the URL
   from sources with a space, `%`, Unicode and `DOMAIN;user`. By hand, on the NAS: open `main`
   and `docker`; a first open with the keychain empty; cancel mid-mount; unplug during a mount;
   hold ↓ through the list with a mount not yet made.

Later, not in this record's steps: the header card.

## Alternatives considered

- **`SMBClient.framework` (private),** `SMBOpenServerEx` and friends — rejected: no header, no
  support promise, and a macOS update can change it without notice.
- **Loading the `smb.bundle` plugin's `EnumerateShares`** — rejected: the interface is public
  but loading a protocol bundle by hand has the same fragility as the framework and more code.
- **`NetFSMountURLSync` of the bare server URL** — rejected: it opens the system's share picker
  window, not a list.
- **Our own SMB client** — rejected: a protocol implementation, authentication included, for a
  list a documented tool already gives.
- **Bonjour only** — rejected: it finds servers, not shares.
- **Naming every row by its share and keeping `child(named:)`** — rejected: an unmounted share
  would resolve to whatever is at `/Volumes/<name>`, another server's included. The typed row
  and the resolver make that unreachable.
- **Merging several mounts of one share into one row** — rejected: Eject and open would need a
  rule for which mount, and 0114's row per mount already has one answer.
- **Mounted shares only on any enumeration failure, without a notice** — rejected: the user
  would take a missing share for a deleted one.
- **Mounting `NoUI`** — rejected: a share that needs a password fails with nothing the user can
  answer.
- **Mounting on any selection** — rejected: holding ↓ would start and cancel a mount per row.
- **Polling the server for new shares** — rejected: a request every few seconds to a NAS for a
  list that changes rarely.
- **Hiding unmounted shares until the user asks** — rejected: Dylan asked for Finder's list.

## Consequences

A server's list is as current as its last enumeration, up to 30 s old, and a share added on the
server needs a reload, a table change or the app becoming active past that age. A rejected
password or an unreachable server is not asked again for 10 s. Parsing `smbutil`'s text can break
when Apple changes it; the fixtures fail then, and the listing shows the failure notice, not a
wrong list; a share type outside the known set does the same for the whole server. Two users on
one host see the first user's list. AFP, NFS and WebDAV servers list mounted shares only, with a
notice. A server with every share ejected is still "not connected". Every user of a server's row
goes through `childLocation(of:)`, which can say "not mounted". A mount may wait on a system
sign-in window with no time limit, and a mount that finishes after a cancel leaves the share
mounted with no navigation. In column view the notice is hidden while a share's column has the
keys.

## For Dylan to check by hand

Before 8c: how Finder behaves on selecting an unmounted share in column view, and on an arrow
stopping on one; whether Escape cancels a mount in Finder; whether Finder updates the share list
live and whether its sidebar row leaves with the last share; the column-view notice's placement;
`smbutil` output for a server with zero disk shares, a printer, a `$` disk share, and a Unicode
or double-space share name, and whether `LC_ALL=en_US.UTF-8` is what gives UTF-8 names.
Before 8d: how `f_mntfromname` writes a share with a space, `%`, Unicode, NFD, a domain user and
a Bonjour host with a space; whether the second share of a session mounts with no prompt;
`AllowUI` showing the sign-in window when the keychain is empty.
