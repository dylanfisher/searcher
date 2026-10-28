# 0124. Tags in rows and the preview, as Finder shows them

- **Date:** 2026-10-27
- **Status:** accepted
- **Builds on:** [0121](0121-tag-commands.md) (tags, their colors and the row menu's dots),
  [0095](0095-preview-metadata.md) (the preview's Tags section),
  [0093](0093-packages-are-files.md) (the listing reads each entry's Finder info),
  [0118](0118-row-eject-buttons.md) (the row's eject button),
  [0039](0039-listing-cache.md) (the listing cache's one shape),
  [0070](0070-context-menus-and-services.md) (the row menu)

## Context

Dylan, 2026-10-27: "tags should look like finder with the color previews", with two
screenshots of one folder in column view. Finder's shows a small dot in the tag's color after
the name of each tagged row, and the preview's Tags section shows each tag as a rounded pill
filled with its color, then an "Add Tag" link. Ours showed no dots, and "Orange" as plain text.
About the row menu's dots (TG.1): "what do you mean by the dots? the colors? these aren't
displaying".

The rules this has to fit:

- AGENTS.md: "No file-system I/O on the main thread. Listings, stats and watches run off the
  main actor."
- 0093: "**Cheap signals only.** `getattrlistbulk` asks for `ATTR_CMN_FNDRINFO` with the other
  attributes, so the bundle bit costs no call."
- 0121: "`NSURL` also sets the legacy color label in `com.apple.FinderInfo`'s `fdFlags` to the
  last colored entry's", and `FinderTags.set(entries:at:)` does the same.
- 0118: the eject button "ends where the chevron starts, else at the cell's edge, and the name
  ends where the button starts".
- 0039: "**One shape.** Every key of the volume, folder and entry dictionaries must be there
  and no other: `size` for a regular file and for nothing else".
- 0095: "**Tags are plain text** … Finder draws each tag's color; `tagNames` has no colors".
- docs/performance.md: B2 (open W2 to its first rows, 100 ms) and B5 (W2 fully listed and
  sorted, 500 ms), which this step must keep within about 5% of before.

## What Finder does, and how it was found

From Dylan's screenshot of Finder (2× pixels, measured on crops):

- **Row dots.** A 10-point circle, its middle about 21 points from the selection's right edge
  and 13 left of the folder chevron's middle, so files' dots line up where a folder's chevron
  would be. On the selected row it has a white outline about a point wide; on other rows a thin
  rim a shade darker than its fill.
- **Preview pills.** "Orange" in the label color on a rounded fill that measures about
  (246, 197, 156) on white: the tag's color, lightened. About 4 points of corner, the name's own
  height plus a point above and below. "Add Tag", in the link color, follows the last pill.
- **A color label with no tags.** `NSURL` reports a tag for an item whose `FinderInfo` holds a
  color label and that has no tags attribute: an item with label 6 alone reads `tagNames`
  ["Red"] and `labelNumber` 6 (a scratch run through JXA).
- **Not seen** in the screenshots, so taken as described below and listed to check by hand:
  several tags on one row, a short name, list view, a tag without a color.

## Decision

- **Tags come with the listing.** The bulk read already returns each entry's Finder info
  (0093); its color label is the last colored tag's, as every write through `NSURL` and through
  `FinderTags` leaves it (0121). An entry with label 0 has no colored tags and isn't read again,
  so a folder of untagged items costs nothing more than its listing: one byte read and compared
  per entry. An entry with a label has its tags attribute read with one `getxattr`, on the
  listing's own thread, as it is parsed (`FinderTags.rowLabels`), which traps on the main
  thread (`aRowsTagColorsAreNeverReadOnTheMainThread`). The entry keeps the colors as
  `TagLabels`: each colored tag's label in the item's order, each color once, four bits a label
  in a `UInt32` that sits in padding `DirectoryEntry` already had, so it stays 48 bytes
  (`tagLabelsFitInTheEntrysPaddingSoTheEntryIsNoLarger`) and W2 takes no more memory (B9). A
  single entry read, for a patch or the stat fallback, reads its Finder info with one
  `getattrlist`, which also gives a folder's bundle bit, so it is the read
  `PackageRule.isPackage(folderAt:)` made for a folder, not a second one
  (`aListingReadsTheColorsOfEachTaggedItemsTags`). A volume that refuses that read with
  `ENOTSUP` or `EINVAL` has no Finder info to give: the entry reads as having none, no tags and
  no bundle bit, rather than failing the listing over a decoration; any other error fails it, as
  before (`aFinderInfoAVolumeCantGiveReadsAsNone`,
  `aFinderInfoReadThatFailsOtherwiseFailsTheEntry`).
- **What a label without readable tags shows.** No tags attribute: the label's color, as
  `NSURL` reports that tag. A tags attribute that can't be read or isn't a list of strings: the
  label's color too, the one color the item is known to have, rather than failing the listing
  over a decoration (`aRowWhoseTagsCantBeReadShowsItsLabelsColor`).
- **Cached with the listing.** A stored entry with colored tags has a `tags` key, its labels;
  one without has none, so an untagged entry stores what it did. A `tags` key that is empty,
  repeats a label or holds one outside 1 to 7 fails the decode and the file is discarded, as
  0039 has it.
- **The row's dots** (`RowTagDotsView`): 10-point circles in each tag's color
  (`NSColor.tagLabel`, `NSWorkspace.fileLabelColors`, the one place the colors come from, which
  the menu's dots use too), each next one half a diameter to the right, the first tag's on top,
  at most three. On an emphasized selection each has a 1-point white outline, elsewhere a
  half-point rim of its color 20% darker. The dots are made the first time a cell shows some,
  as the eject button is, so other rows carry no view. VoiceOver reads the colors in the row's
  label, "tags Orange, Red", so the dots aren't an element of their own.
- **Where the dots go** (`ListingCellLayout`): 4 points after the name, or further left so they
  end before the eject button, else before the not-downloaded badge, else, in a column, 6 points
  before the room a folder's chevron takes whether or not the row shows one (Finder's 13 points
  between the dot's middle and the chevron's), else at the list cell's trailing padding. The name
  truncates before them. The cell fits the two again when the table resizes it, since
  autoresizing would widen the name past dots that follow it. The rename field ends where the
  name does.
- **Rows follow tag changes.** A tag change is an extended-attribute change, which reaches the
  folder's monitor as a modified file (0121), and the pane patches the entry. The entry now
  carries the colors, so a patch that changes them changes the entry and the row is filled
  again; the same patch makes the preview read its tags again (TG.1).
- **The preview's pills** (`TagPillsView`): `ItemInfo.tags` holds the tags' entries with their
  colors, "Orange\n7". The reader reads the tags attribute only when `NSURL` names tags, so an
  item on a volume without extended attributes isn't read for them; when `NSURL` names a tag
  from the color label alone, it gets the label's color. Each pill is the name in the label
  color, 11 points, on its tag's color at 65% (the orange over white comes to about
  (250, 207, 144) against Finder's (246, 197, 156)), 4 points of corner, 5 points of padding
  across and one down, 4 points between pills, wrapping at the preview's width. A tag without a
  color gets `quaternaryLabelColor`, a light gray in both appearances. Both colors and the text
  are dynamic, so dark mode darkens the fill under white text. The pills aren't selectable text,
  as Finder's aren't; VoiceOver reads the Tags title and then each pill's name.
- **No "Add Tag".** It opens Finder's tag editor, a token field with suggestions from every tag
  in use, which TG.1 left out ("Tags…: not built") for the same reasons.
- **Why the menu's dots didn't show: not found.** The menu a right-click builds has the dots,
  in a list and in a column. A right-click or a Control-click on a row's name, icon, tag dot,
  the empty end of its cell or a folder's chevron, sent through the app's queue as a click is,
  builds that row's menu with the seven dots unhidden, sized and each drawn in its tag's color
  (`aMenuPressOnARowsNameCellBuildsTheMenuWithItsTagDotsShown`, 18 cases). In a test run the
  window server's capture of an open menu showed the seven colored circles under Share…. The one
  fault found in them is the check mark (below). TG.1's tests built the menu by calling
  `contextMenu(forRow:)`, which skips the hit test; these send the press as a click.
- **Not a bug: a right-click on a name.** The first version of this step found that a
  right-click on the name or the icon opened no menu, and made the name cell take it. That test
  sent the press with `NSApp.sendEvent` without the app's event loop taking it first, so it
  wasn't the app's current event, and the label and the image view passed it on to nothing. Taken
  from the queue, as every click the user makes is, the press reaches the table from every part
  of the cell without any change, so the override was removed in the review: it read
  `NSApp.currentEvent`, global state, in a hit test.
- **A right-click on the eject button** reaches the table as any press on the row does, and
  builds the row's menu, which lists Eject. What Finder does there wasn't checked: it needs a
  menu opened on the main display. Unverified; to check by hand. A plain press on the button
  ejects and builds no menu (`aPressThroughTheWindowOnAnEjectButtonEjectsAndBuildsNoMenu`).
- **The check mark.** `NSButton` is flipped, so the dot's check, drawn with its point at the
  rect's `minY`, was upside down, a caret. It now points down (`aDotsCheckPointsDown`).
- **The menu's look**, against Finder's row menu: the row of seven circles with the "Tags" line
  under it, where Finder puts its "Tags…" item, and the interaction states of 0121 and 0110,
  unchanged.

## Alternatives considered

- **Read every entry's tags attribute in the listing** — rejected: a `getxattr` per entry, 100k
  calls on W2, for folders that mostly have no tags; the label in the Finder info the listing
  already reads says which entries to read.
- **Read each row's tags as it scrolls in** — rejected: it needs a read per row off the main
  thread and a refill when it lands, with a flash of no dots, for the few rows with tags, which
  the label finds for free.
- **`NSURL`'s `tagNamesKey` per entry** — rejected: a resource-value read per entry, and it has
  no colors.
- **Keep the tags' names in the entry** — rejected: an array per entry grows every listing's
  memory, and a row needs only the colors.
- **Dots always at the cell's end** — rejected: Finder puts them after the name; at the end of
  a column's row they are where a long name puts them anyway.
- **The name cell takes a right-click on its label or icon** — tried, then removed (above): a
  press taken from the queue reaches the table without it.

## Consequences

Tags written straight into the attribute without the color label, which no app writing through
`NSURL` leaves, show no dots until they are written again. A row shows at most three colors.
The colors are the system's label colors, which are Finder's older, lighter ones. A tagged row
measures its name once each time it is filled. A patch, and a listing's stat fallback, read each
file's Finder info with one more `getattrlist`; a folder's was read already.

**Benches to run** (not run in this step): `./scripts/bench` for B2.W2 and B5.W2, and
`./scripts/bench --ui` for B2.W2 open → first rows frame; W2 has no tagged items, so each should
be within noise of the last run. Also `BenchCase+ListingCache` and B9.

**To check by hand:** a row with three or more tags against Finder's (count, overlap, which
dot is on top); a short tagged name in list and column view (the dot right after the name); a
tag without a color in Finder's preview (its pill); dark mode against Finder; a right-click on
the eject button in Finder; Dylan's own right-click on a tagged row, to find what he saw.
