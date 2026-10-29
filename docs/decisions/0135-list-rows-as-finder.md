# 0135. List view's rows, icons and colors as Finder's list view

- **Date:** 2026-10-29
- **Status:** accepted
- **Amends:** [0129](0129-row-icons-as-finder.md) (the icon size, now column view's only)

## Context

Dylan, 2026-10-29, after [0134](0134-link-against-the-current-sdk.md) linked the app against
SDK 27: "did the font size change? now our list view is less compact than finder's. keep it
compact". `tmp/shots/fb-1029-1.jpg` has Searcher's list above Finder's macOS 26 list in one
screenshot, at 2×; `fb-1029-2.jpg` is Finder's alone and `fb-1029-3.jpg` Searcher's.

## What changed with SDK 27, and what Finder draws

Nothing in the list's size changed. `fb-1028c-1.jpg`, taken while the app was still linked
against SDK 14, has the same 24-point rows and 13-point names as `fb-1029-3.jpg`. A test run
linked against SDK 27 reads `NSTableView`'s default `rowHeight` as 24 points, for every
`rowSizeStyle` of a table that isn't a source list, and its `intercellSpacing` as (17, 0); a
label's font is the system font at 13 points, and a header cell's at 11. Both views took
AppKit's 24-point default, and 0129 measured column view only and gave list view its numbers.
What the new look changed is Finder's window beside it, which made the gap plain.

The shots were read pixel by pixel (a script over `sips` BMP conversions); a pixel is ink when
its lowest channel is under 150 for text and 200 for icons.

| | Searcher | Finder's list view |
|---|---|---|
| Row pitch | 48 px, 24 pt | 40 px, 20 pt |
| Name, "DSC0…jpg" | 25 px tall, 175 px wide | 25 px tall, 171 px wide |
| Name text | 13 pt (175.6 px for "DSC01644.jpg" set at 13 pt) | 13 pt |
| A landscape thumbnail | 32 px wide (18-pt frame) | 28 px wide (16-pt frame) |
| Icon middle to the name's first glyph | 15.75 pt | 14.25 pt |
| Name's glyph from its row's top | 7 pt | 5 pt |
| Name text color | (32, 32, 32) | (33, 33, 33) |
| Size, Date Modified, Kind text | (33, 33, 33) | (120, 121, 120) |
| Unsorted header title | (34, 34, 34), 11 pt regular | (120, 121, 120), 11 pt regular |
| Sorted header title | (33, 33, 33), bold | (34, 34, 34), bold |
| Metadata text on the selection | white | (192, 210, 254) on (0, 100, 222): white at about 75% |

Finder's sorted title, "Name", is 61 pixels wide, 4 more than Searcher's regular "Name", and an
11-point bold "Name" sets 64 pixels wide against 61 regular. The names measure the same, so the
text size is right. A 16-point frame draws a landscape
thumbnail 28.4 pixels wide at Searcher's 18-point ratio (32 / 36), Finder's 28. With the icon's
middle 8 points in from its frame, the name's text starts 13 points after the middle, 21 points
into the cell when the icon is 2 points in, as Searcher's is: 3 points from the icon's frame to
the name's field. Finder's header and the selected row's metadata were checked against
AppKit's own drawing: a label in `secondaryLabelColor` in a cell whose background style is
emphasized draws near white, as Finder's does, and AppKit draws the sorted column's title bold
in both apps.

## Decision

- **List view's rows are 20 points, with 16-point icons and the name 3 points after them.**
  `ListingCellLayout.listRows`; column view keeps 0129's 24 points, 18 and 3.5
  (`columnRows`). `ListingViewController` sets `rowHeight` from them rather than taking AppKit's
  default, and asks for thumbnails at its own icon size, 32 pixels in a list.
- **The Size, Date Modified and Kind text is `secondaryLabelColor`**, the name `labelColor`, as
  Finder's are. On an emphasized selection AppKit draws both near white.
- **The header's unsorted titles are `secondaryLabelColor`; the sorted title keeps AppKit's
  `controlTextColor`.** `ListingTableView.HeaderCell` picks the color at each draw from the
  table's first sort descriptor. `labelColor` would draw the sorted title lighter than AppKit's
  own color does (a darkest pixel of 0.37 against 0.30 at 1×). AppKit's bold for the sorted
  title, and the header's hover, press and resize drawing, stay its own.

## Alternatives considered

- **`rowSizeStyle` for the height** — rejected: on macOS 26 the row height of a table that
  isn't a source list stays 24 points at every size style.
- **Column view's 24 points in both** — rejected: Finder draws them apart, and Dylan asked for
  list view as compact as Finder's.
- **Unbold the sorted title** — rejected: Finder's is bold too, measured above.

## Consequences

- The eject button of a volume's row (0118) is 22 points tall, centered in a 20-point row, so
  its hover and press fill reach a point past the row's top and bottom.
- The header stays 28 points with `Margin.standard` (9 points) between it and the first row;
  Finder's first row starts 5 points below its header's line. Finder's header height couldn't
  be read from the shots, the toolbar's glass running into it. Finder also starts its Name
  title where the names start, after the icon; Searcher's starts over the icon.
- The sidebar didn't change under SDK 27: its rows are 24 points in both apps and in both SDK
  linkings (`fb-1028c-1.jpg`, `fb-1029-3.jpg`, `fb-1029-2.jpg`).
- Finder's list view has a per-folder icon size; 16 × 16 is its default, and the one matched.
