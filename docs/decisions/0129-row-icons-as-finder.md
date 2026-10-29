# 0129. Row icons at Finder's 18 points, and folders drawn as Finder draws them

- **Date:** 2026-10-28
- **Status:** accepted
- **Builds on:** [0004](0004-listing-view.md) (one type icon per type in rows),
  [0102](0102-thumbnails.md) (Quick Look thumbnails in rows on local volumes),
  [0046](0046-column-view.md) (the icon 16 points in from the column's edge)

## Context

Dylan, 2026-10-28: "make sure we use same directory icons as finder (and same size). finder is on
right." `tmp/shots/fb-1028b-1.jpg` has Searcher's column view on the left and Finder's on the
right, the same six folders, at 2×; `fb-1028b-2.jpg` is a whole Finder window in column view,
with a grey folder, `_example_files`, that has a grey tag.

## What Finder draws, and how it was measured

The shots were read pixel by pixel (a script over `sips` BMP conversions), counting a pixel as
the icon's when its lowest channel is under 235, and compared with icons drawn by a scratch
program at 2× on white with the same rule. The rows are 48 pixels, 24 points, in both apps, and
the names are the same font and size (the word "audio" is 64 × 19 pixels in both).

| | Searcher before | Finder | Searcher after (computed) |
|---|---|---|---|
| Icon frame | 16 pt | 18 pt | 18 pt |
| Folder drawn, pixels | 30 × 26 | 36–37 × 29–30 | 36 × 28 |
| Icon's left edge from the column's | 16 pt | 16 pt (15.5–16.5 across shots) | 16 pt |
| Name's first glyph from the column's | 38 pt | 39.5 pt (both shots, three columns) | 39.5 pt |
| Gap from the icon frame to the name's field | 4 pt | 3.5 pt | 3.5 pt |
| Icon's vertical middle | the name's | the name's | the name's |

A folder drawn at 16 points comes out 30 × 26 pixels, Searcher's exactly; at 18 points 36 × 28,
and at 19 points 36 × 30. The system's folder icon has an 18-point representation beside 16, 24
and 32, and an 18-point frame draws it. The "after" column is worked out from the layout and
these drawings, not read from a new screenshot.

The look differs too. Down the middle of each folder, Finder's has a near-white band, (223, 255,
255), between a light back flap and the front; Searcher's has a dark back flap, (56, 160, 208),
and no band. The band is a sheet of paper: macOS 26 draws a folder with items in it with a sheet
of paper between its flaps (CoreTypes' `Assets.car` holds `FolderComponent_BackFlap`,
`FolderComponent_PaperSheet` and `FolderComponent_FrontFlap`), a tagged folder in its tag's
color, and a folder with a custom icon in that icon. Measured on this Mac:

- `NSWorkspace.icon(for: .folder)`, `icon(forFile:)` on a plain, a full or a tagged folder,
  `NSImage(named: NSImage.folderName)`, the `effectiveIcon` resource value, the old `'fldr'` file
  type and CoreTypes' `GenericFolderIcon.icns` all draw without the paper, and none tints a
  tagged folder. `icon(forFile:)` gives the `public.folder` type icon's representations.
- Quick Look's `.icon` representation of the folder (`QLThumbnailGenerator`) draws Finder's: the
  paper in a folder with an item, none in an empty one, grey for a grey tag. Its `.thumbnail`
  representation, which rows ask for, has none for a folder.
- Cost, local APFS, one at a time: the first `.icon` of each of 37 folders in `/usr/share`, median
  0.57 ms, at most 41 ms; of 124 in `~/projects`, median 0.81 ms, at most 24 ms. Asked again,
  0.05–0.3 ms.

## Decision

- **18-point icons, the name 3.5 points after them.** `ListingCellLayout.iconSize` is 18 and
  `nameX` is 2 + 18 + 3.5, so the icon's left edge stays where it was and the name moves 1.5
  points right. Rows stay 24 points, as Finder's are, so the tag dots (0124) and the eject button
  (0118), which are placed from the cell's trailing edge and centered in its height, don't move.
  The cell layout is shared, so list view gets the same icon and name position. Thumbnails are
  asked for at the icon's size, 36 pixels at 2×.
- **A folder's row shows Quick Look's icon of it.** `ThumbnailService.shows` takes a folder that
  isn't dataless, and `QuickLookThumbnailer` asks for `.icon` for a directory, which it already
  `lstat`s, in place of `.thumbnail`. Everything else is 0102's: only rows on screen ask, off the
  main thread on a `BlockingCallThread`, in the volume's slots, cached, given up after 5 s, never
  on a network volume, and never for rows the volume hasn't answered with. Until it lands, and on
  a share, the row shows the type icon, as before.
- **Tags are part of the cache key.** A folder's icon follows its tag colors, which change no
  modification date, so `ThumbnailCache.Key` holds the entry's `tagLabels`. A folder whose items
  come or go has a new modification date, so it is asked for again too.
- **The folder's watch reads a child folder again when its items change.** FSEvents names the
  item, `parent/sub/f.txt`, never `parent/sub`, so `FolderMonitor.change(for:in:)` takes an
  event one level inside a child as a change of that child, by the path's first component, and
  reads its entry through the usual patch: once per batch however many of its items had events,
  so a folder being downloaded into costs one `lstat` of it per batch. Deeper events change
  neither the child's entry nor its date, and are dropped as before. The new entry's date is a
  new cache key, so the row asks again and its icon follows.
- **No icon for a volume mounted in a local folder**, as a share in `/Volumes` is: the folder's
  volume says local, but Quick Look would read the share. A row skips a folder its service's
  `MountTable` has a volume mounted at, and asks for no folder before the table's first read,
  which asks again once it lands. Without a table, as in tests, `QuickLookThumbnailer` gives none
  to a directory on another device than its parent. 0118's eject code knows only the volumes the
  sidebar can eject, so the mount table, which knows every mount, decides here.
- **Packages, links, volumes and shares keep their type icons**, as 0093 and 0114 have them; an
  alias is a file and gets the thumbnail 0102 gives it.

## Alternatives considered

- **Keep the shared type icon, at 18 points** — rejected: right size, but every folder is the
  empty one, and a tagged folder stays blue, where Finder's isn't.
- **`NSWorkspace.icon(forFile:)` per folder** — rejected: it gives the type icon, without paper
  or tint, measured above.
- **Compose the folder from CoreTypes' flap and paper assets** — rejected: private asset names,
  and it would still need each folder read for items, tags and a custom icon.
- **19 or 20 points** — rejected: 19 draws the same 36-pixel-wide artwork as 18, scaled, and 20
  draws a 38-pixel folder, wider than Finder's.

## Consequences

- A folder on a network volume shows the empty folder at 18 points: asking Quick Look for its
  icon reads the folder over the share, which 0004 and 0102 keep rows from doing.
- A folder whose items change, or that is retagged, shows the type icon for the moment between
  its row's refresh and its new icon landing, as a file saved again does with its thumbnail.
- The first time a folder is shown in a launch, its row draws the plain folder, then pops to
  Finder's icon when Quick Look's lands: the icons are kept in memory only, so each launch asks
  again, from Quick Look's own cache after the first time.
- The cost figures above are for a warm internal APFS disk only. Cold, external and spinning
  disks weren't measured, nor a scroll through a folder of 10,000 folders.
- The Trash folder draws as a plain folder, as it did before.
- A custom icon set on or taken off a folder shows only because that changes the folder's
  modification date (the `Icon\r` file inside it comes or goes); a tool that set only the
  attribute would leave the old icon until the folder next changes.
- List view's numbers weren't measured from a Finder list view shot; it shares column view's
  cell layout, and Dylan should compare it by hand.
- 0004's "Folders with custom icons show the generic folder icon" and 0102's "custom folder
  icons stay out of scope" no longer hold on local volumes.
