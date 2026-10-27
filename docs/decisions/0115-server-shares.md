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
  prompt: the seven above as type `Disk`, and `IPC$` as type `Pipe`. `-N` is "don't prompt for a
  password". The host is the mount source's host as the mount table gives it. It exits 0; a wrong
  user exits 77 with "server rejected the authentication" on stderr. Against an address with
  nothing there it blocked 60 s ("Operation timed out"), so it needs the bound below.
- The public NetFS headers (`NetFS.h`) offer `NetFSMountURLSync`, `NetFSMountURLAsync`,
  `NetFSMountURLCancel`, `NetFSMountURLProbe` and `NetFSCopyURLForRemountingVolume`, and no call
  that lists shares. `EnumerateShares` appears only in `NetFSPlugin.h`, the interface the
  protocol bundles implement (`/System/Library/Filesystems/NetFSPlugins/smb.bundle`). A mount of a
  bare server URL opens the system's share picker window. `SMBClient.framework` is private,
  and `SMBOpenServerEx` is in it with no header in the SDK.
- Bonjour (`_smb._tcp`) names a server and gives its address, never its shares.

Claims about Finder marked *(unverified)* weren't checked in Finder; each is checked by hand
before the step that builds it.

## Decision

- **Enumeration: `smbutil view -N`, for SMB.** A documented system tool (`smbutil(1)`) that
  reuses the session the mounted share holds. Public API has no enumeration, so the choice is a
  subprocess, the private framework, or the plugin interface. The private framework has no
  header or support promise; loading a protocol bundle by hand is the same risk with more code;
  speaking SMB2 ourselves is a new protocol stack. The cost of the subprocess is its text
  output, which a fixture test pins (below). The command runs as `smbutil view -N
  //<user>@<host>`, with `<user>` and `<host>` from the mount source as written and `LC_ALL=C`.
  An enumerator is a closure from `Server` to share names, so a test passes its own.
- **A server needs a mounted share to be listed,** as 0114 has it: its user comes from that
  share's source, and the session it holds is what `-N` reuses. A server with no share mounted
  is `notConnected` as before; whether `smbutil -N` would also work from the keychain alone with
  no session is *(unverified)* and not relied on. Finder's own sidebar row goes with the last
  share *(unverified)*.
- **Which names.** Only type `Disk` and no name ending in `$`: this drops `IPC$`, printers and
  administrative shares. Finder's 7 items for the 8 listed confirm `IPC$` is dropped; whether it
  hides a disk share such as `C$` is *(unverified)*. NetFS marks such shares `IsHidden`
  (`kNetFSIsHiddenKey`), so the rule has the system's concept behind it. A mounted share is
  listed whatever its name.
- **What the other protocols get.** AFP, NFS and WebDAV servers list their mounted shares only,
  as 0114 does, and the pane says so in its notice: "Only mounted shares are listed for AFP
  servers." Nothing public lists AFP shares, `showmount` covers NFSv3 exports only, and a WebDAV
  URL is one share. `VolumeIdentity` gains the file system type (`f_fstypename`, already read
  with `MNT_NOWAIT`) to tell `smbfs` from `afpfs`. A server with shares of two protocols gets
  the SMB enumeration, and its other shares stay as mounted.
- **Where it runs.** Under [0038](0038-slow-volumes.md): the subprocess is started and waited on
  from a `BlockingCallThread`, `requireCurrent` checked first; one enumeration per server in
  flight, a second asker joins it. At `LoadTimeouts.slow` (3 s) the pane gets `slow` as a load
  does; at the give-up time (30 s) the process is terminated and the result is `unreachable`.
  Time comes from the injected `Clock`. Nothing in this record runs on the main actor.
- **The merge.** `ListingService.load` of a server asks the `MountTable` for the server's
  mounted shares and `ServerShares` for the enumerated names, and lists the union, one
  `.directory` entry per share, each named by the share's name as the server writes it
  (`volume.share`, the last component of the mount source, percent-decoded). This replaces
  0114's name from the mount point's last component, so a second mount of "main" at
  `/Volumes/main 1` is still "main". Identity is the share name compared without case, as SMB
  does. An enumerated name with no mounted share is *unmounted*; a mounted share the server
  didn't list (a `$` share, a share since removed) stays, mounted. An unmounted entry's path is
  `/Volumes/<name>`, 0114's `child(named:)`, which doesn't exist until it is mounted; the pane
  keeps the set of unmounted names, and the commands that need a folder read it, so nothing
  touches the missing folder.
- **What an unmounted share shows.** The same row as a mounted one: `GenericSharepoint` icon (the
  screenshot shows one icon for both), Kind "Volume", `--` for Size and Date Modified. Only a
  mounted share has Eject, in the row and the context menu (0114). An unmounted share's
  context menu has Open only. Get Info, Quick Look, Copy, Open in Other Pane, Open in Terminal
  and Add to Sidebar are off for it, because they need the folder.
- **Showing and refreshing.** Enumeration results are cached per server for 30 s, and a
  load shows the cached names at once while it asks again when they are older. A server pane
  asks when it loads, when the `MountTable` reports a change to that server's shares, and when
  the app becomes active; nothing polls, and nothing is written to disk. A share added on the
  server shows at the next of these. Finder updates a server's list live *(unverified)*.
- **When enumeration fails.** The state is `failed` with the mounted rows kept, as an offline
  pane keeps its rows ([0038](0038-slow-volumes.md), `KeptRows` with `isComplete` false), and
  the pane's notice gives the reason: "Couldn't list the shares on “HAL9000”: The server
  rejected the password." Exit 77 gives the rejection; a timeout gives `unreachable`; any other
  exit shows smbutil's stderr line. The mounted rows aren't shown as a whole listing without the
  notice. An empty result with exit 0 lists the mounted shares and says nothing, since the
  server has no other share.
- **Mounting: `NetFSMountURLAsync`.** Opening an unmounted share (Return, double-click, ⌘↓,
  Open, and in column view selecting its row, which is how a column opens) mounts it. The URL is
  built from a mounted share's source, with no file-system call: `smb://<user>@<host>/<share>`,
  the share percent-encoded, `afp` for `afpfs`. `NetFSCopyURLForRemountingVolume` would `statfs`
  a path, which 0038 keeps off hung shares. `mountpath` is nil, so the system mounts under
  `/Volumes` and names the folder; the result's first mount point is where the pane goes.
  `open_options` carries `UIOption: AllowUI`, so the system shows its own sign-in window only if
  the existing session and keychain don't cover the share; `NoUI` would fail with no way to
  answer. Whether the second share of a session mounts with no prompt is *(unverified)*,
  checked by hand in 8c. `mount_options` is empty: soft and browsable are the defaults.
- **Where mounting runs and what shows.** The `NetFSMountURLAsync` call starts on a
  `BlockingCallThread`, since the header doesn't promise it returns before connecting, and its
  completion block resumes a continuation. One mount per share in flight; a second open of the
  same share joins it. After `LoadTimeouts.spinner` (150 ms) the row shows a spinner in the
  place of Eject and the status bar says "Connecting to “main”…". Mounting has no give-up time,
  since the sign-in window may be waiting for the user. Escape, or selecting another row, or
  leaving the server, cancels with `NetFSMountURLCancel`, which also stops the completion block;
  Finder cancels the same way *(unverified)*. On success the pane goes into the mount point if it
  is still at that server with that share selected; otherwise the share just becomes a mounted
  row. A canceled mount (-128) shows nothing. Any other status shows a sheet, as 0108's eject
  failure does: "The share “main” couldn’t be opened." with the reason under it, from `strerror`
  for a positive status and a short text for the NetAuth and `ENETFS…` codes the header lists
  (password rejected, no shares available, no authentication method); an unknown code shows
  as "Error -6600." Already mounted (`EEXIST`) goes to the share as success.
- **Header card.** Not in steps 8a to 8c; recommended as 8d, after Dylan answers. "Connected
  as" is the user in the mount source, Disconnect is 0114's eject of the whole server, and the
  card scrolls with the rows in column view. List view has no place for it.
- **Accessibility.** An unmounted share reads as its name with Kind "Volume" and "not mounted";
  the spinner has a label, "Connecting"; the notice reads as a folder's failure does.
- **Dependency.** `import NetFS` links a system framework, as `IOKit` and `CoreServices` are
  linked today. It is not a package or a third-party dependency, so principle 7 doesn't apply;
  Dylan is asked anyway below, since the line is his. `/usr/bin/smbutil` is the same kind of
  thing, a tool the system ships.

## Build steps

In order; each lands with its tests, and each test fails without the step. Tests of a path the
user can reach go through the real `ListingService`, panes, views and `MountTable` stub; fakes
stand in for the subprocess, `NetFS` and the clock only.

1. **SB.8a, the share list** (Browser). `ShareNames` (parses `smbutil view` output by the
   header's column positions, drops non-`Disk` and `$` names), `ServerShares` (cache, TTL, one
   in flight per server, slow and give-up times from `LoadTimeouts`), the `smbutil` runner on a
   `BlockingCallThread`, and `VolumeIdentity` gaining `share`, `user` and the file system type.
   Files: `Sources/Browser/ShareNames.swift`, `ServerShares.swift`, `SmbutilShares.swift`,
   `VolumeIdentity.swift`; their tests. Tests: this machine's output as a fixture (eight rows,
   seven kept); names with spaces; a `Printer` row; "0 shares listed"; exit 77 and a timeout
   each give their own error; a second ask joins the first; a cache hit within 30 s and a new
   read after, on a hand-moved clock; the runner is told to terminate at the give-up time.
2. **SB.8b, the merged listing** (Browser, Interface). Server load merges mounted and
   enumerated shares; unmounted set on the pane; `failed` with kept rows and the notice;
   refresh on a table change and on app activation; no Eject, and commands off, for unmounted
   rows. Files: `ListingService.swift`, `ListingState.swift`, `Pane.swift`,
   `ListingViewController.swift`, `ColumnViewController.swift`, `ContextMenuBuilder.swift`,
   `EntryCellFormatter.swift`, `main.swift`. Tests, in a window: a stub table with one mounted
   share and an enumerator of three lists three rows, one with Eject; a share mounted later gets
   Eject with no second row; a failing enumerator shows the mounted row and the notice with its
   reason; AFP shows its notice; a name differing in case merges; "main 1" lists as "main"; the
   views show the icon, "Volume" and `--` for an unmounted row; Quick Look and Get Info are off
   on it.
3. **SB.8c, mounting** (Browser, Interface). `ShareMounter` over `NetFSMountURLAsync`, the
   open paths, the spinner and status text, cancel, the failure sheet, the pane going into the
   mount point. Files: `ShareMounter.swift`, `Pane.swift`, `ListingViewController.swift`,
   `ColumnViewController.swift`, `FileCommands.swift`, `PaneViewController.swift`. Tests, in a
   window with a fake mounter: Return on an unmounted share starts one mount, a second Return
   joins it; success puts the pane in the mount point, and not when the pane has moved; Escape
   cancels and shows no sheet; a failure shows the sheet with the reason, each status
   family once; the spinner shows only after 150 ms on the injected clock; the URL built from a
   source with a space and a `%` in the share name. By hand, on the NAS: open `main`, `docker`;
   a first open with the keychain empty; cancel mid-mount; unplug during a mount.
4. **SB.8d, the header card** (Interface), if Dylan approves. The card in the server's column,
   "Connected as: <user>", Disconnect as 0114's eject. Tests: the card's text from the source's
   user, Disconnect unmounts every share with the refusal sheet of 0114.

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
- **Mounted shares only on any enumeration failure, without a notice** — rejected: the user
  would take a missing share for a deleted one.
- **Mounting `NoUI`** — rejected: a share that needs a password fails with nothing the user can
  answer.
- **Polling the server for new shares** — rejected: a request every few seconds to a NAS for a
  list that changes rarely.
- **Hiding unmounted shares until the user asks** — rejected: Dylan asked for Finder's list.

## Consequences

A server's list is as current as its last enumeration, up to 30 s old, and a share added on the
server needs a reload, a table change or the app becoming active to appear. Parsing `smbutil`'s
text can break when Apple changes its columns; the fixture test fails then, and the listing
shows the failure notice, not a wrong list. AFP, NFS and WebDAV servers still list mounted
shares only, with a notice saying so. A server with every share ejected is still "not
connected". An unmounted share's path exists only after it is mounted, so every user of an
entry reads the pane's unmounted set first. A mount may wait on a system sign-in window with no
time limit.

## Questions for Dylan

1. Is linking NetFS, and shelling out to `/usr/bin/smbutil`, acceptable under the dependency
   rule? The record treats both as system parts, not dependencies.
2. The header card (server icon, "Connected as", Disconnect): now as 8d, or later? Recommended
   later: it is separate from the list you asked for, and list view has no place for it.
3. Is AFP and NFS showing mounted shares only, with a notice, acceptable for now?
4. Cancelling a mount with Escape or by selecting another row: Finder's behavior is
   *(unverified)*; should it be checked in Finder before 8c?
