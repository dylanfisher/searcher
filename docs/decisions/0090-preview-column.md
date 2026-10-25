# 0090. Preview column: the selected file's listing fields, right of the last column

- **Date:** 2026-10-24
- **Status:** accepted

## Context

Column view had no preview column ([0041](0041-column-model.md), [0046](0046-column-view.md)):
selecting a file only truncated the columns to its right. Dylan asked for column view to work
more like Finder's, which shows the selected file's icon and details to the right of the last
column. B6 (16 ms from key to frame) holds in column view, so the preview can't read the file or
make a view per selection. Thumbnails cost 85 ms per file over SMB
([0004](0004-listing-view.md)), and the created date, last-opened date and tags need a read the
listing doesn't make.

## Decision

- **The preview is part of the trail, not a column.** `ColumnTrail.preview` is a
  `ColumnPreview`: the file's location, its `DirectoryEntry` and its `EntryKind`, all from the
  last column's listing. It is set when the last column's selection is one entry that isn't a
  folder or a link, and nil for a folder (which opens its column, as before), a link, several
  rows or none. It
  holds no `Pane`, lists, watches and takes the keys for nothing, so → on a file still does
  nothing.
- **It follows the listing.** The trail recomputes it on each change the last column reports, so
  a patch to the file's size or date shows at once, and a removal, which drops the name from the
  selection, clears it. A rename shows the new name when the selection follows it.
- **Links show no preview; special files do.** Open treats a link to a folder as its folder
  (`Pane.openLink`), so such a link shows no preview, as a folder doesn't. Telling a link to a
  folder from a link to a file takes a read, which the preview never makes, so no link shows
  one; a link to a file loses Finder's preview until a read off the main thread (CV.3) can tell
  them apart. A socket, device or FIFO shows a preview with its kind and no size, as Finder
  shows one.
- **Packages follow the trail.** The preview shows for what the trail doesn't open as a column.
  A package such as an app is a file to Open and the trail
  ([0093](0093-packages-are-files.md)), so it opens no column and shows the preview, with no
  size: its size is a walked folder size, which the preview doesn't show yet.
- **One view, refilled.** `ColumnViewController` makes `ColumnPreviewView` the first time a file
  is previewed, keeps it in the columns' document view, hides it when there is no preview and
  refills its fields only when the preview changes. It sits right of the last column's separator,
  one column wide (240 points). Its icon is the type's shared icon from `TypeIconCache` at 128
  points, so showing it reads nothing.
- **Layout follows Finder's preview.** The icon at the top, the name below it centered and
  wrapping, the kind and size in secondary text, then an Information section with Size and
  Modified rows, titles right-aligned in secondary text. Colors are system colors, so it follows
  light and dark mode. Each field is held to the column's width: a long name wraps, breaking
  inside a word that has no space, and a long kind or date truncates. In a window shorter than
  the fields they scroll vertically, in a scroll view with no horizontal scrolling of its own.
  (Superseded 2026-10-24: the name and the kind and size are left-aligned, the Information
  section has no Size row, since the size is in the line under the name, and its rows are drawn as Finder draws them, title left and value right with a rule under each row,
  in the small system font, and a long date wraps; see
  [0095](0095-preview-metadata.md).)
- **Scrolling.** The column view scrolls when the focus, the column count or whether a preview
  shows changes. The focused column's right-hand neighbor, kept in view where it fits, is the
  next column or, from the last column, the preview.
- **VoiceOver.** The preview view is a group labeled with the file's name, whose children are its
  text fields in reading order. It follows the columns among the browser's children while shown.

## Alternatives considered

- **Make the preview a `Column` or give it a `Pane`** — rejected: a column lists, watches and
  takes the keys, and the preview needs none of that; → would have to skip it.
- **Read the file's attributes for the preview** — not in this step: created, last opened and
  tags need a cancelable read off the main thread (CV.3). (Superseded 2026-10-24: the preview
  reads them off the main thread once it shows, see
  [0095](0095-preview-metadata.md).)
- **Thumbnails** — not until CV.4, which generates one file's thumbnail asynchronously after the
  selection settles. Until then the preview shows the type icon.
- **Build the preview view on each selection** — rejected: a held ↓ through files would make a
  view hierarchy per row, against B6.
- **Show the preview for a package** — left out of this step, which didn't decide what Open and
  the trail do with packages; [0093](0093-packages-are-files.md) made them files, and they
  preview.

## Consequences

Selecting a file can now scroll the column view, to bring the preview in beside the focused
column. Column view always shows the preview; there is no setting to hide it yet. The preview's
width is the columns' fixed width until columns can be resized (CV.5) (superseded 2026-10-24: the
preview has its own grip and starts at the width new columns get, see
[0096](0096-column-widths.md)). A held arrow key through
files refills the preview's fields on every row (superseded 2026-10-24: a preview reached by
keys shows once they pause, see [0094](0094-column-open-delay.md)).
