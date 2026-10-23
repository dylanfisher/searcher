# 0030. Mark iCloud files that aren't downloaded with a badge after the name

- **Date:** 2026-10-22
- **Status:** accepted

## Context

An iCloud Drive file whose contents were evicted, or never downloaded, has the `SF_DATALESS`
flag, which the lister already reads ([0028](0028-folded-names.md)). Finder marks such a file
with a cloud and down arrow after its name. Browsing a folder must not download anything: any
read of a dataless file's contents makes the system fetch it, so the listing may only look at
what the directory read returned.

## Decision

- **Symbol.** The badge is the system symbol `icloud.and.arrow.down`, the cloud with a down arrow
  Finder shows, tinted with the secondary label color. `TypeIconCache` makes it once, the first
  time a row needs it, and every row shares the image.
- **Place.** Each name cell has a hidden 16-point image view at its trailing edge. A dataless
  entry shows it and narrows the name by its width; any other entry hides it and gives the width
  back. The cell is configured the same way whether the table made it, reused it, or the row is
  refilled in place ([0029](0029-row-movement.md)), so a badge never outlives its entry. The
  name's width is set from the cell's, never shifted by the badge's, and set again when the Name
  column resizes: autoresizing clamps a width at zero in a column narrower than the name and the
  badge, and a shifted width would carry that error from then on.
- **VoiceOver.** The row's label ends with "Not downloaded", and the badge is not an
  accessibility element, so the state is read once ([0040](0040-list-accessibility.md)).
- **No reads.** The row's icon still comes from its type, looked up from the name's extension,
  and the size is the logical size from the bulk read (`ATTR_FILE_DATALENGTH`). Nothing in the
  listing or icon path opens a file or asks for its thumbnail or preview; the lister reads
  attributes only, with `getattrlistbulk` and `fstatat`, and neither downloads a dataless file.

## Alternatives considered

- **`icloud` or `arrow.down.circle`** — rejected: neither is what Finder shows for an evicted
  file, and the plain cloud reads as "in iCloud", true of downloaded files too.
- **A label on the name's text field** — rejected: a static text with both a label and a value is
  read differently by VoiceOver versions, and could hide the name. A separate element keeps the
  name read as it is.
- **Always reserving the badge's room** — rejected: it cuts every name short in folders with no
  iCloud files at all.
- **`NSWorkspace.icon(forFile:)` for dataless files** — rejected: it's a per-file call and the
  list never makes one ([0004](0004-listing-view.md)).

## Consequences

Opening a dataless file, or listing a dataless folder, still downloads it; that is the user's
action. A process-wide `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, ...)` set to
off would turn any accidental read into an error instead of a download, but it would also block
those intended ones, so it isn't set.
