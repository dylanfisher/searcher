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
  points, so showing it reads nothing. (Amended 2026-10-25, from Dylan: "preview area needs a
  right border to show where you can drag to resize it", and "metadata area should have a
  minimum width". The preview has the columns' one-point separator line at its right edge,
  under its grip ([0096](0096-column-widths.md)), shown and hidden with it. Its width is at
  least `Settings.previewWidths`' lower bound, 200 points, where a column's is 100: at 100 the
  icon, 128 points then, was wider than the preview and the centered fields ran off its left
  edge, cutting off the Information titles. 200 leaves, inside the 12-point insets, the widest
  title, "Last opened", whole and about 110 points beside it for the value, room for
  "Wednesday," and a date's other words, so a long date wraps by words onto three lines. The
  preview's grip stops there; an Option-drag or Option-double-click that takes the columns
  narrower leaves the preview at 200, and the default width a preview with none set follows
  is held to it. A stored preview width below it is discarded, like one out of range.)
- **Layout follows Finder's preview.** The icon at the top, the name below it centered and
  wrapping, the kind and size in secondary text, then an Information section with Size and
  Modified rows, titles right-aligned in secondary text. Colors are system colors, so it follows
  light and dark mode. Each field is held to the column's width: a long name wraps, breaking
  inside a word that has no space, and a long kind or date truncates. In a window shorter than
  the fields they scroll vertically, in a scroll view with no horizontal scrolling of its own.
  (Superseded 2026-10-24: the name and the kind and size are left-aligned, the Information
  section has no Size row, since the size is in the line under the name, and its rows are drawn as Finder draws them, title left and value right with a rule under each row,
  in the small system font, and a long date wraps; see
  [0095](0095-preview-metadata.md).) (Amended 2026-10-25, from Dylan: "always show preview
  images so that they are scaled to fill the width of the preview space, unless that would push
  the metadata down, in which case it should be scaled down a bit, like finder does". His
  screenshot showed a portrait photo drawn about 150 points wide in a 550-point preview. The
  image, thumbnail or type icon, is now as wide as the fields, the preview's width less its
  12-point insets, at the image's aspect, a type icon square. When that is taller than the
  preview leaves above the fields, between its 24-point margins, it is scaled down, keeping its
  aspect, until the last Information row ends at the bottom margin, though to no less than
  `ColumnPreviewView.smallestImageSide`, 64 points; in a window shorter than that the fields
  scroll, as before. The tags below the rows don't count: they show only once read, and
  counting them would shrink the image and move every row up when a read lands after the
  hold ([0095](0095-preview-metadata.md)); they scroll instead. It is sized again when the preview's width or height changes and when its
  file or fields change, so a thumbnail of another aspect, or tags that add a line, resize it
  in the same layout. The thumbnail is asked for at the size drawn; see
  [0102](0102-thumbnails.md).)
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
  selection settles. Until then the preview shows the type icon. (Superseded 2026-10-25: the
  preview shows the file's thumbnail once made; see [0102](0102-thumbnails.md).)
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

## Update 2026-10-25: a press anywhere in a pane focuses it

Dylan found that a press on the empty space below or right of the preview's fields gave the pane
no focus. The cause: `NSWindow.sendEvent` makes the hit view first responder only when it accepts
the keys. The preview, its stack, the gaps past the columns, the path bar and the status area are
plain views that don't, and their `mouseDown` went up the responder chain to nothing. A row, or
the empty area of a table below its rows, hits the table, which does take the keys; so list view
and a column's own empty area already focused the pane.

`PaneContainerView`, the pane's root, now takes any press that reaches it and makes the pane's
`keyView` first responder, as a press on a row does (`Pane.didGainFocus` follows from the table
becoming first responder). In column view `keyView` is the focused column's table, so a press in
the preview leaves the focused column as it was, and the selection is not touched. Controls keep
their presses because they take them before the container sees them: the CV.10 grips, the path
bar's buttons, the filter field, the rename field, Access Denied's button.

The preview's name, tags and values were selectable wrapping labels. A selectable label takes the
keys and tracks the mouse itself, so a press on its text would not have reached the pane; they are
no longer selectable. Finder's preview text is not selectable either, as recalled; Dylan to
confirm. A press on empty space below a table's rows is left to AppKit, which clears the selection in
that table at mouse up, as Finder's columns do ([0077](0077-selection-history.md) relies on it);
it is not tested, since the test windows are not key (0091) and AppKit selects nothing then. A
press in the preview's empty space, the gaps or the bars changes no selection (tested).
