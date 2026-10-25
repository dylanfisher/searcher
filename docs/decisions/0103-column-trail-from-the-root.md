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
  where a share not mounted yet, or an ejected disk, would be; any other starts at `/`.
- **Built at once, checked off the main thread.** The mount table needs a read, which can't run
  on the main thread, and a trail has to show on the frame that built it. So `init` takes the
  root from the path (the rule above with an empty table, right for the startup disk and
  `/Volumes`) and asks `ListingService.trailRoot(of:)`, which reads the table on a
  `BlockingCallThread` (`getmntinfo` with `MNT_NOWAIT`, asking no volume). A different answer
  drops the columns above the real root, or adds the ones missing above the first column. Only a
  volume mounted outside `/Volumes`, or a `MNT_DONTBROWSE` one inside it, gives a different
  answer, so the columns of a normal trail never move after its first frame.
- **The focused column lists first.** The columns above it are made with
  `Pane(waitingAt:)`, which lists nothing. Their loads start once the focused column's first
  update lands, whatever it is (rows, cached rows, slow, a failure), and the root check has
  answered, so a column the check drops never lists. ← or a click into one of them starts them
  at once. The focused column's load is asked first, at `.focused` priority when the pane has the
  keys ([0048](0048-pane-load-priority.md)); the others are asked after every load already
  waiting, at the pane's priority. On a share they wait behind its one read in flight
  ([0038](0038-slow-volumes.md)); a column whose folder is on a slow or gone share shows its
  state ([0046](0046-column-view.md)) and holds nothing else.
- **The way down stays.** A column built above the focused one keeps the column right of it while
  its selection is the one the trail gave it (`Column.keepsNextColumnAt`), whatever its rows show
  of the next folder: a hidden folder its rows leave out, a link the path went through (`/tmp`),
  a package, cached rows from before the folder was made, or no rows at all because the folder
  can't be listed. Its row isn't shown or selected then. Finder shows a hidden folder dimmed in
  its parent's column; that takes a row the listing doesn't have, so it isn't done here. A column
  that can't be listed shows its message ([0046](0046-column-view.md)); the path bar names the
  folder. Any other selection in that column follows as before.
- **← at the root does nothing,** without a beep, as in Finder. Cmd-↑ is ← in column view
  ([0041](0041-column-model.md)), so it stops there too. ← no longer adds a parent's column: there
  is none above the root.
- **A path bar click focuses the column** that shows the clicked folder (`Pane.showFolderAbove`),
  as a click in that column does: no selection changes, the columns right of it stay, nothing
  lists again, and it is no step of the history. The pane's location, the path bar and the title
  follow the focus, so the bar then ends at the clicked folder, as Finder's does. A folder above
  the trail's root, such as `/` or `Volumes` for a trail at `/Volumes/X`, has no column: the
  click navigates to it, selecting the folder it came from, as in the list.
- **Scrolling.** A new trail (no column kept) is scrolled from the left end, so the focused
  column, with the one right of it where that fits, ends at the right edge and the columns above
  it fill the view to its left. It jumps, as a new trail did ([0046](0046-column-view.md)). A
  trail shown before the column view had a width scrolled to nothing, so the view scrolls again,
  once, when it first gets a width.

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
  selections. Not now; the cost is below.
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
reads queue behind the destination's on the share's one read slot. A folder above the trail's
root is reached only from the path bar or Go to Folder.

The path bar still starts at `/` ([0026](0026-path-bar.md)), so for a folder on `/Volumes/X` it
shows `/` and `Volumes`, which have no columns. The trail's first column is `/Volumes/X`.
