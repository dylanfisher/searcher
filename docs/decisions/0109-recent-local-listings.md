# 0109. Recent local listings: a revisited local folder shows its last rows at once

- **Date:** 2026-10-26
- **Status:** accepted

## Context

Dylan, 2026-10-26: "switching between two directories back and forth in column view still
flashes. it should be immediate if we have already visited it", and earlier, "in general i want
to avoid flash." A pane that moves, and a new column of a trail, start with no rows (`loading`)
until `ListingService.load` hands over a listing from its thread. Even a warm local listing
lands a main-queue turn or more after the move, so the view draws the folder empty in between.
[0103](0103-column-trail-from-the-root.md) keeps the columns two trails share, but a sibling
folder is a new column each time.

Network folders show cached rows first ([0045](0045-cached-rows-first.md)), but those come from
the load's thread too, after an actor hop and a sort, so they would also miss the move's frame.
[0039](0039-listing-cache.md) rejected caching local volumes ("no gain against a warm local
listing") by counting the listing's time and not the blank frames between the move and its
first update.

## Decision

- **What is kept.** `RecentListings`, owned by the `ListingService` the app makes and shared by
  its panes: per folder path, the `Listing` a pane last showed in the `loaded` state and when it
  was listed. A listing lands there from a load's full listing, a monitor's patch or a sort, so
  the entry follows the folder as the pane saw it. `Listing` is a value whose arrays are shared
  with the pane showing it, so a folder still on screen costs nothing extra. Only folders whose
  pane's volume (`Pane.folderVolume`) is local are kept; network folders keep using
  `ListingCache`. (Amended 2026-10-26, Dylan, on folders that are "mostly on an SMB share":
  "move up/down between directories still causes all items to flash. it seems like these could
  be cached or more performant if i've just viewed them." Folders on every volume are kept, a
  share's too, so a share folder revisited in the same launch shows its rows in the move's turn
  as a local one does, then refreshes. `ListingCache` is unchanged and still gives a share's
  rows on a folder's first visit of a launch and across launches; once a pane shows kept rows,
  its cached update is ignored, as any cached update is when the pane has rows (0045).)
- **Memory only.** Nothing is written to disk, and nothing is kept across launches.
- **Shown in the move's turn.** `Pane.startLoad`, which every move, Back and Forward, a new
  pane and a new column go through, looks the folder up when the pane has no rows and shows the
  kept listing as `cachedRefreshing` before it starts the load, so the view's first draw after
  the move has the rows. The lookup is a dictionary read on the main actor. The selection, a
  name at most after a move, is found in the rows there too. The load always runs, and its full
  listing replaces the rows, so they are stale for one listing at most. A first batch doesn't
  replace them (0045).
- **Only in the pane's arrangement.** A kept listing in another sort, folders-first or hidden
  setting, or filter isn't shown: its rows would show in the wrong order until a sort landed,
  and sorting on the main actor costs more than the blank frame.
- **Bounds.** At most `defaultFolderCap` (100) folders and `defaultEntryCap` (50,000) entries;
  past either, the least recently used folders go. A folder with more entries than the cap alone
  isn't kept. B9 allows 60 MB per 100k entries of a `Listing`, so 50,000 entries are at most
  30 MB beyond the listings on screen. W1-shaped folders (~300 entries) fill the folder cap at
  30,000 entries. W2 (100k) isn't kept: its first batch already shows within 7–9 ms (spike S4).
- **Dropped when the folder is gone.** A load that fails, or finds its volume gone, drops the
  folder and every folder under it. A monitor's patch that removes an entry drops the folder of
  that name; folders under it go when their own loads fail. A volume mounting or unmounting
  (`VolumeEvents`, [0049](0049-volume-events.md)) drops every folder at or under its mount
  point, so a different volume mounted at the same path never shows the old one's rows.
  (Amended 2026-10-26: so do will-unmount and the sidebar's will-eject
  ([0108](0108-sidebar-locations.md)), so a folder opened while the volume goes doesn't show its
  rows. A share that goes slow or gives up keeps its folders: the pane shows them slow or
  offline, as it would the listing cache's (0045). A load that fails, `unreachable` included,
  or finds its volume gone, drops them as above.)
- **Bench mode keeps none.** The UI bench's service is made without one, so B2's and B6's cases
  keep timing a real load.

## Alternatives considered

- **Cache local folders in `ListingCache`** — rejected: its lookups are actor calls that hand
  rows over from the load's thread, which misses the move's frame, and it keeps entries, which
  need a sort before they show.
- **Hand the kept rows from the load's thread as `ListingUpdate.cached`** — rejected for the
  same reason: the move's turn ends with no rows, and the view draws it.
- **Sort a kept listing in another arrangement on the main actor** — rejected: O(n log n) on
  the main actor for every revisit after a sort change.
- **Bound by bytes** — rejected for the reason 0045 gives: entries are what B9 counts.

## Consequences

A folder changed while no pane showed it shows its old rows until its listing lands, a few
milliseconds on a local disk, with the spinner's wait; on a share, as long as the share takes to
list it, as the listing cache's rows already did. A folder deleted under a kept folder whose
parent wasn't shown shows its old rows until its load fails. Folder sizes in a kept listing are
the ones it showed. The UI bench doesn't measure revisits of local folders.
