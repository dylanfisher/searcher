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
  preview for a file it hasn't read: at once after a click, after the pause after keys. The
  reader and its dispatch queue are the owner pane's `itemInfoReader` and `itemInfoQueue`, a
  global queue at user-initiated QoS reached through a continuation, as `linkCheckQueue` is, so a
  blocked read holds a dispatch thread and not one of the cooperative pool's. The result lands in
  `ColumnPreview.info` as `.read` or `.failed`.
- **Stale results are dropped.** A preview of another file, no preview, a navigation, list mode
  and closing the pane cancel the read's task, and a result lands only if its task wasn't
  cancelled and its file is still the preview. A read already on its thread runs to its end; only
  its result is dropped.
- **No read when it could wait on nothing.** A dataless entry gets none, and neither does a file
  whose column shows rows its volume hasn't answered with: cached rows, or a slow or offline
  state's rows. `ListingState.isAnswered` is true only for `.partial` and `.loaded`. When the
  column's load lands, or a patch downloads the file, the trail starts the read then.
- **One read per preview.** The same file staying previewed keeps what was read, through patches
  to its size or date. A tag change made elsewhere shows when the file is previewed again.
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
- **A serial queue for the reads** — rejected: one read stuck on a share would hold up every later
  preview's read, local files included.
- **Re-read on every patch to the previewed file** — rejected: patches come from writes to the
  contents, which change none of these fields, and a growing download would read once per patch.
- **Read in the view controller** — rejected: the trail already knows when the preview changes,
  closes and waits for the keys, and keeping the read there lets Browser tests hold it without a
  window.

## Consequences

B6: a key that moves the selection starts no read; the read starts once per shown preview, after
the pause, and its landing refills the preview's fields as a patch does. B10: every read is off
the main thread, and on W6 a column that is slow or offline starts none. A read that started
before a share went bad holds one dispatch thread until the share answers or the kernel gives up.
Tag colors are left for a later step.
