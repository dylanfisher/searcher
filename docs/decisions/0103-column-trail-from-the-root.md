# 0103. Column trail from the root: every folder above the pane's has its column

- **Date:** 2026-10-25
- **Status:** accepted

## Context

Dylan, 2026-10-25: "if you are nested into several levels deep in a column, clicking breadcrumbs
should keep the other existing panels open if they were in the same directory. it currently goes
to a fresh window where the first pane is the directory you clicked, and you lose your other
panes. lets actually just make it so that in column mode all columns in the heirarchy/braedcrumbs
are always shown, like finder does".

Until now a trail started with one column at the pane's folder
([0041](0041-column-model.md)): switching to columns, a navigation, Back and Forward, a restore
and a workspace load all built one column, ← past the first column added the parent's column,
and a path bar click navigated, closing every column. `TabState` keeps a column-mode pane's
focused folder only ([0041](0041-column-model.md), [0096](0096-column-widths.md),
[0098](0098-column-widths-per-window.md)), so a restore showed one column too.

## Decision

- **The trail starts at the root.** `ColumnTrail.init` builds a column for each folder from the
  root of the folder's volume down to its parent, each with the next folder selected, then the
  focused column at the folder with the entry under the cursor selected. Every way a trail is
  built goes through it: Cmd-3, Go to Folder, the sidebar, the palette, Back and Forward, a
  link, a split's copy, a session restore and a workspace load. `TabState` is unchanged: the
  trail above the focused folder is rebuilt from its path, and the columns right of it from the
  cursor, as before.
- **Which root.** `ColumnTrail.root(of:mountedVolumes:)`: the longest mount point in the
  kernel's mount table that holds the path by its text, so a share mounted at
  `/Users/me/mnt/share` starts there. A volume mounted `MNT_DONTBROWSE` is no root, as Finder
  doesn't show it as a volume: firmlinked folders such as `/Users` are on the Data volume, mounted
  at `/System/Volumes/Data`, and start at `/` as Finder shows them, and so does a path typed
  through `/System/Volumes/Data`. `VolumeIdentity.isBrowsable` carries the flag; it isn't part of
  the identity. With no such volume, a path under `/Volumes/X` starts at `/Volumes/X`, which is
  where a share not mounted yet, or an ejected disk, would be, unless a `MNT_DONTBROWSE` volume
  is mounted there; any other starts at `/`. Names compare without case and with Unicode
  normalized (`FileOperation.comparable`), as APFS compares them by default, so `/volumes/x/a`
  starts at its own `/volumes/x`; the root is spelled as the path spells it, since the columns
  are the path's folders. On a case-sensitive startup disk a folder `/volumes/x` that isn't
  `/Volumes/x` would start at itself, losing the columns above it; such a disk is rare.
  (Amended 2026-10-25, Dylan: "add a preference to show directories relative to root user (like
  finder) instead of / root (but you can still navigate up to root either way, like finder)":
  with `Settings.columnsStartAtHome` on, the default, as Finder's column view starts a folder
  in the home folder at the home folder, a trail for the home folder or a folder inside it
  starts at the home folder, so its first column is `~`. `root(of:mountedVolumes:home:)` takes
  the deeper of the volume's root and the home folder, compared by the same text rule, so a
  share mounted at `~/mnt/share` still starts at its mount point, and a home folder on another
  volume starts at the home folder. It needs no read: the home folder is `Settings.home`, the
  one place it is read, which `~` in Go to Folder and the palette and a new window's folder
  also use. The trail keeps the home folder it was built with, and the root check passes it to
  `ListingService.trailRoot(of:home:)`, so the check doesn't add the columns above home back.
  Off, a trail starts at the volume's root as above. Folders outside home, such as
  `/Applications`, `/Users`, `/tmp` or `/Volumes/X`, start at the volume's root either way.
  Turning the setting on or off restarts each open trail at the root its focused column's
  folder has then, as a root check that answers differently does: the columns above home close,
  or are added, each with the next folder selected; the focused column and the columns right of
  it stay, nothing lists again but the added columns, and it is no step of the history. Finder
  applies such view options to the windows it opens next; here every open column view follows
  at once, as the other View menu settings do. `TabState` still keeps the focused folder only, so
  a restore or a workspace load builds its trail with the setting as it is then.)
- **The path's text, not the folder's real path.** The trail is the folders the path names. A
  path through a link keeps the link: `/tmp/a` shows `/`, `tmp`, `a`, with `tmp` a link in the
  `/` column, and `/Volumes/Macintosh HD/Users` (a link to `/`) shows `/`, `Volumes`,
  `Macintosh HD`, `Users`. Resolving the path takes a file-system read, which the trail can't
  wait for before its first frame. Finder may resolve such paths (Go to Folder `/tmp` may show
  `private` › `tmp`); that isn't checked here and is a hand check.
- **Built at once, checked off the main thread.** The mount table needs a read, which can't run
  on the main thread, and a trail has to show on the frame that built it. So `init` takes the
  root from the path (the rule above with an empty table, right for the startup disk and
  `/Volumes`) and asks `ListingService.trailRoot(of:)`, which reads the table on a
  `BlockingCallThread` (`getmntinfo` with `MNT_NOWAIT`, asking no volume). A different answer
  drops the columns above the real root, or adds the ones missing above the first column (a
  `MNT_DONTBROWSE` volume at `/Volumes/X` adds `/` and `Volumes`). Only a volume mounted outside
  `/Volumes`, or a `MNT_DONTBROWSE` one inside it, gives a different answer, so the columns of a
  normal trail never move after its first frame.
- **The focused column lists first.** The columns above it are made with
  `Pane(waitingAt:)`, which lists nothing. Their loads start once the focused column's first
  update lands, whatever it is (rows, cached rows, slow, a failure), and the root check has
  answered, so a column the check drops never lists. ← or a click into one of them starts them
  at once. The focused column's load is asked first, at `.focused` priority when the pane has the
  keys ([0048](0048-pane-load-priority.md)); the others are asked after every load already
  waiting, at the pane's priority. On a share they wait behind its one read in flight
  ([0038](0038-slow-volumes.md)); a column whose folder is on a slow or gone share shows its
  state ([0046](0046-column-view.md)) and holds nothing else. (Amended 2026-10-25, Dylan: "in
  general i want to avoid flash": the columns above wait for the root check only, not for the
  focused column's first update. The focused column's load is still asked first: it is asked as
  the trail is built, and the check answers after a thread hop, and `ListingService` starts
  loads in the order asked once their volumes are known. A folder that is slow to list no
  longer holds back the small folders above it, which before showed empty until it answered.
  A column the check drops is closed before the waiting loads start, so it still never lists.)
- **The way down stays.** A column built above the focused one keeps the column right of it while
  its selection is the one the trail gave it (`Column.keepsNextColumnAt`), whatever its rows show
  of the next folder: a hidden folder its rows leave out, a link the path went through (`/tmp`),
  a package, cached rows from before the folder was made, or no rows at all because the folder
  can't be listed. Its row isn't shown or selected then. Finder shows a hidden folder dimmed in
  its parent's column; that takes a row the listing doesn't have, so it isn't done here. A column
  that can't be listed shows its message ([0046](0046-column-view.md)); the path bar names the
  folder. Any other selection in that column follows as before. Once the column's rows have
  listed the next folder, rows that no longer list it mean it went, removed or renamed: the
  column right of it closes, as a removed folder's column does in any column, and the column
  follows its selection as any column does from then on.
- **The lead column closing first.** A column above can list early, when its folder monitor
  reports a change, and a selection there can close the column the trail was built at before
  that column's first update. The columns still waiting then list once the root is checked, as
  if that update had come. (Superseded 2026-10-25: the columns above no longer wait for that
  update, so there is nothing to handle; see the amendment above.)
- **← at the root does nothing,** without a beep, as in Finder. Cmd-↑ is ← in column view
  ([0041](0041-column-model.md)), so it stops there too. ← no longer adds a parent's column: there
  is none above the root. (Amended 2026-10-25, Dylan: "but you can still navigate up to root
  either way, like finder": ← in a first column at the home folder does nothing too, as Finder's
  ← does in its leftmost column. Cmd-↑ there goes on up: the pane navigates to the home folder's
  parent, selecting the home folder, as Finder's Enclosing Folder goes above the home folder, so
  it is a step of the history and the new trail starts at that folder's root, `/`, with the
  home folder selected in `Users` and its column open (`ColumnTrail.moveUp`). Everywhere else
  Cmd-↑ is still ←, and at a volume's root it still does nothing, so with the setting off
  nothing changes. The path bar, Go to Folder, the sidebar and Back reach `/` and `Users` as any
  folder above the root: they navigate, and the trail is built at that folder by the rule. Back
  to a folder the current trail shows still focuses its column, so Back from `/Users` to `~`
  after a Cmd-↑ keeps the trail from `/`.)
- **A path bar click focuses the column** that shows the clicked folder (`Pane.showFolderAbove`),
  as a click in that column does: no selection changes, the columns right of it stay, nothing
  lists again, and it is no step of the history. The pane's location, the path bar and the title
  follow the focus, so the bar then ends at the clicked folder, as Finder's does. A folder above
  the trail's root, such as `/` or `Volumes` for a trail at `/Volumes/X`, has no column: the
  click navigates to it, selecting the folder it came from, as in the list. (Amended 2026-10-25,
  Dylan: "clicking the breadcrumbs in column mode should close the columns to the right, only
  keep the columns to the left open. keep the current behavior where navigating left on panes
  continue to keep the right panes open, though.": the clicked folder's column takes the keys and
  becomes the last one (`ColumnTrail.showAlone`). The folder the path went on to stays its
  cursor, unselected, so it opens no column, as Finder's path bar shows the clicked folder last;
  ↓ goes on from it. Nothing lists again, but a column whose first load waits. The click is a
  step of the history, as every move of the keys to another column now is
  ([0041](0041-column-model.md)), so Back returns to the folder left, building its trail again
  since its column closed. ← still keeps the columns to the right.)
- **Scrolling.** A new trail (no column kept) is scrolled from the left end, so the focused
  column, with the one right of it where that fits, ends at the right edge and the columns above
  it fill the view to its left. It jumps, as a new trail did ([0046](0046-column-view.md)). A
  trail shown before the column view had a width scrolled to nothing, so the view scrolls again,
  once, when it first gets a width. (Amended 2026-10-25: a trail started again with columns kept
  (below) scrolls from where the view is, animated, as a move within the trail does; one that
  keeps none still jumps.)
- **Starting again keeps the columns both trails show.** (Added 2026-10-25, Dylan: "when i use
  back/forward the panes on left flash/get re-drawn, even if it was the same pane on left
  visible in both states … in general i want to avoid flash".) Back or Forward to a folder the
  trail doesn't show, Go to Folder, the sidebar, the palette, a link and a path bar click above
  the trail start it again (`ColumnTrail.init(owner:at:selecting:replacing:)`). The old trail's
  columns from its root down, as far as their folders are the new trail's from the new root
  down, stay: the same `Column` and `Pane`, so their rows, monitors and column views stay, and
  nothing lists or redraws them. Each kept column above the new focused one selects the next
  folder on the new way down and keeps the next column as a built one does (`keepsNextColumnAt`,
  above); a kept column at the destination itself takes the keys with the remembered entry
  selected, and the column that entry opens is made new. The old trail's other columns close.
  The new root is taken from the path, as for any new trail, so different roots, such as home
  and `/` for `/Applications`, keep nothing, and the root check corrects the trail as before.
  The kept columns take the sort of the old focused column, as the new ones do, and lose their
  filters, as a navigation clears a filter ([0041](0041-column-model.md)). Their selections are
  no steps of their selection histories, and the trail moves the keys without a step of the
  pane's history: the step is the navigation's, or none for Back and Forward. A kept column
  that was still waiting to list waits for the new root check, or lists at once when it is the
  new focused column. List view is unchanged.

## Alternatives considered

- **Only the breadcrumb fix** (Dylan's first ask): keep the trail as it was and focus a column
  the path bar names. Rejected by Dylan's second sentence; it is part of this change.
- **The root from the path text alone** (`/Volumes/X` or `/`): one rule, no read. Rejected: a
  share mounted elsewhere would start at `/` and list every local folder above it, and the brief
  asks for the volume, not the text.
- **Wait for the mount table before building the trail**: the trail would show one frame late,
  or the restore would wait on a thread hop for each column-mode pane.
- **Keep a mount table in the service and read it synchronously**: still empty at launch, when
  restores build their trails, so the check is needed anyway.
- **Ancestors at `.hidden` priority** instead of waiting for the focused column's first update:
  they would also wait behind other panes' hidden tabs and never get ahead of a hidden load, and
  the order within the pane would still race on each load's volume read.
- **Reuse the old trail's columns on a navigation** within the same tree, so the folders above
  aren't listed again: a navigation closes every column and clears filters
  ([0041](0041-column-model.md)); keeping some would need rules for their filters, sorts and
  selections. Not now; the cost is below. (Taken up 2026-10-25, with the rules above: see
  "Starting again keeps the columns both trails show".)
- **Keep the old trail's columns by folder anywhere in it**, not only the leading ones shared
  from the root: a column right of a folder that differs shows a folder the new trail doesn't
  run through, so there is nothing more to keep.
- **Beep on ← at the root**: Finder doesn't.

## Consequences

Building a trail N folders deep lists N folders instead of one, makes N column controllers and
tables on the main thread instead of one, and starts N folder monitors. The folders above a
typical one (`/`, `/Users`, `/Users/me`, `~/projects`) are small, and each read runs off the main
thread on the service's background slots, after the focused column's first update, so the
focused column's first rows come as they did. Each extra column costs the main thread what → into
a loaded folder costs (B6), all on the frame that builds the trail; a trail eight deep makes seven
of them at once. No bench was run for this step. Benches to run: `./scripts/bench --ui` (the
column-view B6 cases and B10), and `./scripts/bench --ui --scenario restored-session` (B1, 500 ms;
its panes are list panes, so it measures the change only if a column-mode pane is added to the
saved session). A restore of a column-mode pane asks its ancestors' loads after every other
restored pane's focused folder, since those were asked first.

Every navigation in column view lists the folders above the destination again; on a share, those
reads queue behind the destination's on the share's one read slot. (Amended 2026-10-25: only the
folders above it that the old trail didn't show list; the ones it shared keep their rows. The
columns above a new trail now ask their loads as soon as the root check answers, so they can
take a share's read slot while the focused folder's read is still running, where before they
waited for its first update.) A folder above the trail's
root is reached only from the path bar or Go to Folder.

The path bar still starts at `/` ([0026](0026-path-bar.md)), so for a folder on `/Volumes/X` it
shows `/` and `Volumes`, which have no columns. The trail's first column is `/Volumes/X`. With
`Settings.columnsStartAtHome` on, the same holds for `/` and `Users` above the home folder, and
a trail in the home folder lists two fewer folders on each navigation.
