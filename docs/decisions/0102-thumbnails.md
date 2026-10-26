# 0102. Thumbnails in rows and the column preview, from Quick Look, rows never on a share

- **Date:** 2026-10-25
- **Status:** accepted

## Context

Dylan, 2026-10-25: "we should show preview thumbnail in metadata and in the list view like
finder does, ideally using the same thumbnails finder already has so we don't do any extra work
and keep it performant." His screenshots: Finder's preview column shows the file's thumbnail
large above the name, a JSON file showing its app's document icon; Finder's list rows show small
photo thumbnails for .jpg files in place of the generic icon.

[0004](0004-listing-view.md) kept lists to per-type icons and rejected per-file thumbnails in
lists because a Quick Look thumbnail costs 85 ms per audio file over SMB, and said to revisit
when a "show previews" setting moves thumbnails into lists. [0090](0090-preview-column.md) left
the preview's thumbnail for later. Blocking calls run on a `BlockingCallThread` with per-volume
limits ([0038](0038-slow-volumes.md)); the preview's reads go through per-volume slots and are
held for at most 100 ms so a new file doesn't flash ([0095](0095-preview-metadata.md)); a file
that isn't downloaded is never read ([0030](0030-not-downloaded-badge.md)).

A probe on this Mac (local APFS, generated 2000×1500 JPEGs, `QLThumbnailGenerator`):

- `generateBestRepresentation(for:completionHandler:)` returns to its caller in 0.01–0.4 ms; the
  image comes later on a queue of Quick Look's. The work runs in Quick Look's own process.
- A file never thumbnailed: 17–28 ms (112 ms for the first request in the process). The same file
  again: about 1 ms, from the system thumbnail cache, which Finder fills too. 16 requests at
  once: 66 ms for all.
- `.icon` returns the type's icon (0.2 ms), the same icon `TypeIconCache` already shows.
  `.thumbnail` with `iconMode` returns the photo in Finder's rounded frame, and for JSON or plain
  text a page of text, not the document icon Dylan's screenshot shows for JSON.
- There is no public way to ask for cached thumbnails only.

## Decision

- **Source: Quick Look.** `QuickLookThumbnailer` (Base) asks `QLThumbnailGenerator` for the
  `.thumbnail` representation with `iconMode`, at `ThumbnailService.scale` (2). It uses the
  system's thumbnail cache, so a file Finder has shown costs about 1 ms. A file Quick Look has no
  thumbnail for keeps its type icon. `ThumbnailMaking` is its protocol, so tests hold requests
  with `GatedThumbnailMaker`.
- **Text keeps its type icon.** `EntryKind.isText` (conforms to `public.text`, not an image, so
  SVG still gets one): JSON, source code and plain text show their icon in rows and the preview,
  as Dylan's screenshot shows JSON. Quick Look's page of text is unreadable at 16 points.
- **Which files.** `ThumbnailService.shows`: a regular file whose contents are on this Mac and
  which isn't text. Folders, packages, links, special files and dataless files keep their icons;
  custom folder icons stay out of scope. Rows and the preview ask only for files in rows the
  volume answered with (`ListingState.isAnswered`), not cached, slow or offline rows.
- **Not downloaded, checked again.** The listing's `SF_DATALESS` flag can be stale, so
  `QuickLookThumbnailer` reads the flag with `lstat`, which doesn't download, on the request's
  thread just before asking Quick Look, and gives a dataless file none. A file evicted in the
  microseconds between that `lstat` and Quick Look's open can still be downloaded; nothing short
  of the process-wide `IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES` policy, which 0030 declined,
  closes that.
- **Rows never on a network volume, the preview's one file yes, placed by the folder's
  volume.** A request names the volume of its folder as the folder's load read it with `statfs`
  (`Pane.folderVolume`, from `ListingLoad.volume`, kept through a reload of the same folder and
  copied into a split's copy), not the path's text. A folder reached through a link under `/`
  onto a share (`~/nas -> /Volumes/nas`) is on the share. A row on a network volume gets none
  and no request is made: 0004's 85 ms per file stands, and a screen of rows would have Quick
  Look read each file over the share. A folder whose volume no load has read yet asks for none.
  The column preview's one file on a share does get one (2026-10-26). Dylan: "image preview
  isn't working for images on network drives", and Finder's column preview shows the selected
  image on a share. The preview reads one file, after the keys pause.
  `ThumbnailService.makes(on:forPreview:)` holds the rule. The preview's request on a share
  follows 0038: it takes the share's one thumbnail slot (`ListingService.mostReads(on:)`),
  apart from the share's loads and info reads and from every other volume's slots, and is
  started on a `BlockingCallThread`. When the selection moves on, the trail cancels it. On a
  share a cancelled request being made is stopped (`QLThumbnailGenerator.cancel`) and ends the
  caller's wait at once, rather than running on to fill the cache as a local one does; one
  waiting is never made. So arrowing through a folder on a share leaves only the latest file's
  request running or waiting. `QLThumbnailGenerator.cancel` doesn't promise that Quick Look's
  process stops reading the file, so the stopped read and the next one may overlap on the share
  for a moment; how long, if at all, isn't measured. A stopped request isn't kept as having
  none, so the file is asked again when selected again. A share's preview is given up after
  `ThumbnailService.shareGiveUp`, 30 s, not 5 s: a RAW photo over SMB can take longer than
  5 s, nothing else needs that slot, and moving the selection cancels it. One given up isn't
  kept as having none either, so reselecting the file asks again. The preview shows the type
  icon, or a smaller kept thumbnail, until the image lands, and keeps it if the request fails
  or is given up. A share that stops answering inside Quick Look's own process holds only that
  slot. One that stops answering the `lstat` before Quick Look holds the request's thread and
  slot until it answers, as 0038 has a hung load hold its share's; the caller's wait still
  ends on cancel or give-up, and the slot is freed once the call returns. Requests behind it
  wait without a thread and are dropped as the selection moves on. Not measured on the NAS:
  how long a preview thumbnail takes over SMB.
- **Threads and slots follow 0038.** The cache, the volume and the task's cancellation are
  checked on the caller's thread first, so a row already kept, on a share or scrolled away costs
  no thread. A volume has at most `ListingService.mostReads(on:)` requests making a thumbnail at
  once (four on a local volume), in slots of their own (`ThumbnailService.calls`, an
  `InfoReads`), apart from loads' and info reads'. A request that gets a slot starts Quick Look
  on a `BlockingCallThread`: the call returns at once on local disk, but what it does in-process
  before handing on isn't documented, and a thread per request costs tens of microseconds.
  Requests past that wait without a thread, in the order asked, the preview's ahead of rows'
  (`first`), so the CV.12 hold isn't spent behind a screen of rows. One cancelled while waiting
  is never made.
- **Given up after 5 s.** A slot is held until Quick Look answers or `ThumbnailService.giveUp`
  (5 s, on the service's injected clock) passes. Then the request is cancelled
  (`QLThumbnailGenerator.cancel`), its slot freed for the next request, and it ends with no
  thumbnail; Quick Look's answer, if it still comes, does nothing. The file is kept as having
  none for that version, so a file that hangs Quick Look holds a slot once, not each time its
  row scrolls into view; it is asked again once it changes or the cache drops it. A local
  thumbnail takes 1–112 ms, so 5 s is a broken file, a stalled disk or a Quick Look that stopped
  answering, and without it four such requests would stop every thumbnail on the volume and
  leave the preview held until its 100 ms ran out on every file. The preview on a share has
  30 s and keeps nothing when it gives up (above).
- **One cache.** `ThumbnailService` keeps thumbnails in a `ThumbnailCache`: least recently used
  dropped first past 32 MB (about 7,000 row thumbnails or 120 preview ones; amended 2026-10-25:
  about eight preview ones at the largest side, below, which can evict most of the 32 MB, so
  row thumbnails are asked for again on scroll-back; the cache is plain LRU), keyed by path,
  modification date, size and pixel side, so a file saved again is asked for again. A file with
  no thumbnail, and one given up, is kept as having none, so scrolling back asks nothing.
  `ListingService.thumbnails` holds the service, so every pane, column and copy shares it; nil,
  as in tests and benches that don't pass one, shows type icons only.
- **Rows: only on screen.** `ListingViewController`, which draws list view and each column of
  column view, asks for the rows in `visibleRect` after each reload or patch and on each scroll
  or resize (the clip view's bounds and frame, the table's frame). Requests of rows that left the
  screen, or whose entry or folder changed, are cancelled. A landed thumbnail is set in its row's
  cell if the row is still there with that entry; a cell made or refilled later takes it from the
  cache. Per row on the main thread: building the path, a locked dictionary lookup, and wrapping
  the `CGImage` in an `NSImage`. Quick Look's image is already pixels, so nothing is decoded on
  the main thread.
- **The preview: thumbnail in the icon's square.** `ColumnTrail` makes the preview's 128-point
  thumbnail beside its info read, under the same rules (none for a dataless file or rows the
  volume hasn't answered with), and keeps it through patches until the new one lands, as the info
  is kept. `ColumnPreview.thumbnail` replaces the type icon in the same 128-point square, so
  nothing moves when it lands. (Amended 2026-10-25: the preview now draws its image as wide as
  its fields, or smaller to keep them in view ([0090](0090-preview-column.md)), up to 976
  points at the widest preview, so a 128-point thumbnail would be drawn scaled up, blurred.
  Column view works out, at each layout, the longest side the preview could draw its image at,
  its width inside the insets or its height inside the margins, whichever is longer, since a
  portrait image's aspect isn't known before it is made, and sets it as
  `Pane.previewImageSide`, rounded up to 64 points (`ColumnPreview.imageSide`) so a resize of a
  few points asks for nothing, and at most `ColumnPreview.largestImageSide`, 512 points: 1024
  pixels at scale 2, about 3 MB for a 4:3 photo. The trail asks for the thumbnail at that side;
  a column view 560 points tall or more asks for 512. When the side grows, by a grip's drag or
  a taller window, the trail asks again for the file shown, keeping its thumbnail, not the icon,
  until the larger one lands, and keeping it if that one fails; a smaller side asks for nothing.
  The rules above stand: off the main thread, the preview's request first in its volume's
  slots, cancelled on change, local volumes only (amended 2026-10-26: on shares too, above),
  given up after 5 s. A thumbnail landing after the hold now replaces a type icon drawn as
  large, a bigger jump than in the 128-point square, and a thumbnail of another aspect than the
  icon's resizes the image, moving the fields below it. A one-off measure on this Mac (local
  APFS, a scratch program asking `QLThumbnailGenerator` for `.thumbnail` with `iconMode` at
  scale 2, as `QuickLookThumbnailer` does, for JPEGs written fresh so nothing was cached: 12 MP
  4:3, 2000×1500 and 12 MP portrait, five files each): a file's first 256-pixel thumbnail took
  14–17 ms, its first 1024-pixel one 35–39 ms (median 35), and either again 1.4–2.7 ms from
  the cache. So a local photo's preview thumbnail lands well inside the 100 ms hold. These test
  photos carry no embedded thumbnail; HEIC, RAW and video files and a busy or spinning disk
  weren't measured, and can take longer. Whatever it takes, a file whose smaller thumbnail is
  kept, such as its row's, never shows its type icon in the preview: the trail shows the
  largest smaller one kept of that version (`ThumbnailService.cachedSmaller`, from a per-file
  index of the sizes the cache holds, so nothing walks the cache), scaled up, until the
  preview's own lands, and keeps it if that one fails. That shown thumbnail also ends the
  hold's wait for one, so the file shows as soon as its info is read.)
- **The CV.12 hold waits for the thumbnail too.** A newly previewed file is held until its info
  is read and its thumbnail made, or `previewHold` (100 ms) passes. A local thumbnail, 1–28 ms,
  lands inside it, so the file shows with its thumbnail from its first frame and no icon flashes
  before it. One that lands later replaces the icon in place. A kept thumbnail shows at once.

## Alternatives considered

- **`.icon` or `.all` representations** — rejected: `.icon` is the type icon rows already show;
  `.all` gives text files a page of text.
- **Let Quick Look decide for text too** — rejected: it makes a page of text for JSON, where
  Dylan's screenshot of Finder shows the document icon.
- **Thumbnails in rows on network volumes** — rejected, per 0004's measure. The preview was
  rejected too, since a thumbnail reads the file over the share and Quick Look's own queue can't
  be bounded from here, until Dylan asked for it (amended 2026-10-26, above): one file at a time,
  stopped when the selection moves on, bounds it.
- **Place a file by its path's text in the mount table** — rejected: a folder reached through a
  link onto a share places as `/`, and every photo there would be read over the share.
- **`statfs` per request** — rejected: on a share that stopped answering each one blocks a
  thread before any per-volume limit applies (0038's consequence); the load has read it already.
- **Retry a given-up thumbnail each time its row shows** — rejected: a file that always hangs
  Quick Look would hold a slot for 5 s on every scroll past it.
- **Cached thumbnails only** — not available: Quick Look has no public cache-only request.
- **Request from `tableView(_:viewFor:row:)` and cancel in `didRemove`** — rejected: the table
  prepares rows beyond the visible ones, and a prepared row scrolled into view is never asked
  for again.
- **A global queue or the cooperative pool to start requests** — rejected per 0038.
- **`NSCache`** — rejected: its eviction order is undocumented; the cache is a small LRU instead.
- **Per-display scale** — rejected: the trail has no window to ask. 2x on a 1x display costs a
  row 3 KB.

## Consequences

This narrows 0004: rows show per-file thumbnails for local, downloaded, non-text files. B6: a key
press asks for nothing new unless it scrolls; the preview's thumbnail starts after the pause, as
its info read does. B10: no request blocks the main thread, and a share's rows get none
(amended 2026-10-26: the preview's one file on a share does). Scrolling a folder of photos
starts a thread and a Quick Look request per newly visible row, four at a time; the UI benches
and a by-hand scroll through a large photo folder should confirm scroll budgets.
A file replaced by another with the same path, date and size keeps the old thumbnail until the
cache drops it. A thumbnail Quick Look is slow to make once, past 5 s, as a large video on a
disk that is spinning up, stays an icon until the file changes or the cache drops it. Folders
with custom icons still show the generic icon. A list whose controller is dropped leaves its
waiting requests to run.
