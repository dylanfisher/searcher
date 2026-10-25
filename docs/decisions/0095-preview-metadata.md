# 0095. Preview metadata: Created, Last opened and Tags, read off the main thread

- **Date:** 2026-10-24
- **Status:** accepted

## Context

Column view's preview ([0090](0090-preview-column.md)) shows only what the listing has: icon,
name, kind, size and modified date. Finder's preview also shows when the file was created, when
it was last opened and its tags, in the order Kind, Size, Created, Modified, Last opened, then
Tags. None of those is in the `getattrlistbulk` listing, so showing them takes a read per file.
The preview shows once the keys pause ([0094](0094-column-open-delay.md)), so a held arrow key
makes no preview and would make no read. The read can still block: a file on a share that is slow
or gone ([0038](0038-slow-volumes.md)) holds the calling thread, and an iCloud file that isn't
downloaded ([0030](0030-not-downloaded-badge.md)) has no contents on this Mac. Packages are files
([0093](0093-packages-are-files.md)), and Finder shows the same fields for an app.

## Decision

- **`ItemInfoReader` in Base reads one item.** It returns `ItemInfo`: the creation date and the
  tag names from the URL's resource values (`creationDateKey`, `tagNamesKey`), and the last-opened
  date from Spotlight's record of that one item, `MDItemCreate` then `MDItemCopyAttribute` with
  `kMDItemLastUsedDate`. `ItemInfoReading` is its protocol, so a pane can hold a stub.
- **Last opened comes from `MDItem`.** It is the only correct source: no URL resource value holds
  `kMDItemLastUsedDate`, and `contentAccessDateKey` is the file's atime, which isn't the date
  Finder shows. A one-off probe on local APFS took about 0.6 ms per file, and about 10 ms for the
  first call in a process, which connects to the metadata server; it doesn't block on Spotlight's
  index. A file Spotlight has no date for shows "--". This reads one file's attributes; it is not
  a search, and nothing here builds on `NSMetadataQuery`.
- **The trail reads, once the preview shows.** `ColumnTrail` starts the read when it sets a
  preview for a file it hasn't read: at once after a click, after the pause after keys. It reads
  with the owner pane's `itemInfoReader` through `ListingService.readInfo`. The result lands in
  `ColumnPreview.info` as `.read` or `.failed`.
- **Reads follow [0038](0038-slow-volumes.md).** Each read runs on a `BlockingCallThread`, never
  on a GCD queue or the cooperative pool: a read blocked on a hung share holds that one thread,
  and no worker other work needs. A volume has at most `ListingService.mostReads(on:)` reads in
  flight, one on a network volume and four on a local one, placed by the mount table
  (`getmntinfo` with `MNT_NOWAIT`, which asks no volume). These slots are apart from the loads',
  so a preview read never holds back a listing. A read that finds its volume's slots taken waits,
  without a thread, in the order asked, and starts when the read ahead of it returns; a waiting
  read whose preview moved on is dropped and never reads. So a share that dies while its column
  still shows `.loaded` rows costs one blocked thread, however many files the user clicks through.
- **Stale results are dropped.** A preview of another file, no preview, a navigation, list mode
  and closing the pane cancel the read's task, and a result lands only if its task wasn't
  cancelled and its file is still the preview. A read already on its thread runs to its end; only
  its result is dropped.
- **No read when it could wait on nothing.** A dataless entry gets none, and neither does a file
  whose column shows rows its volume hasn't answered with: cached rows, or a slow or offline
  state's rows. `ListingState.isAnswered` is true only for `.partial` and `.loaded`. When the
  column's load lands, or a patch downloads the file, the trail starts the read then.
- **One read per file version.** The same file staying previewed keeps what was read through
  patches to other entries. A patch that changes its own entry, such as its size or modified
  date, as a file deleted and made again or saved by replacing it, starts a new read; the fields
  keep what was read before until it lands, so they don't blank. A failed read is likewise tried
  again only once the file's entry changes, or when the file is previewed again. A tag change made elsewhere changes no entry, so it shows when the file is previewed again.
- **The layout doesn't move when the read lands.** The Created and Last opened rows are in the
  Information grid from the first frame, empty until read, between Size and Modified and after
  Modified. Tags are a section below every other field, shown only when the file has tags, so
  they only add height below. A read with no date, and a failed read, show "--", as Finder shows
  an unknown value. A file that gets no read keeps its rows empty.
- **Tags are plain text**, joined with ", " in Finder's order, wrapping to the column's width.
  Finder draws each tag's color; `tagNames` has no colors, and reading them takes the label
  colors from Finder's preferences, which this step leaves out.
- **`scripts/arch` denies `MDItemCreate` in Interface and the app**, with the other file-system
  calls, so the read stays in Base and runs off the main thread.

## Alternatives considered

- **Hide the Created and Last opened rows until read** — rejected: the Modified row would move
  down when the read landed.
- **"--" while the read runs** — rejected: it reads as "no date" for the length of the read.
- **The `com.apple.lastuseddate#PS` extended attribute** — rejected: one `getxattr` would be
  cheaper, but files Spotlight has a last-used date for don't all carry it (the probe's files had
  none), so it misses dates Finder shows.
- **A global dispatch queue for the reads** — rejected, as 0038 rejects it for loads: each hung
  read holds a worker, and once GCD stops adding workers, unrelated work on global queues stalls.
- **One serial queue for every read** — rejected: one read stuck on a share would hold up every
  later preview's read, local files included. The slots are per volume instead.
- **Drop a read whose share's slot is taken** — rejected: on a share that is only slow, clicking
  through files would leave the fields empty for each file clicked while a read ran.
- **Keep the read while the file's location stays** — rejected: a file replaced under its name
  would keep its old Created date and tags, and a failed read would stay failed.
- **Read in the view controller** — rejected: the trail already knows when the preview changes,
  closes and waits for the keys, and keeping the read there lets Browser tests hold it without a
  window.

## Consequences

B6: a key that moves the selection starts no read; the read starts once per shown preview, after
the pause, and its landing refills the preview's fields as a patch does. B10: every read is off
the main thread, and on W6 a column that is slow or offline starts none. A read that started
before a share went bad holds one `BlockingCallThread` until the share answers or the kernel
gives up, and the share's later reads wait behind it. A file that keeps changing, such as a
download, is read again at each patch, one read at a time on a share. Tag colors are left for a
later step.
