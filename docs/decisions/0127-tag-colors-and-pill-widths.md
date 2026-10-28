# 0127. Finder's tag colors, and pills as wide as their names

- **Date:** 2026-10-28
- **Status:** accepted
- **Builds on:** [0124](0124-tags-in-rows-and-preview.md) (the row's dots and the preview's
  pills), [0121](0121-tag-commands.md) (the row menu's dots and the label numbers)

## Context

Dylan, 2026-10-28, with screenshots of one tagged file in Searcher and in Finder
(`tmp/shots/fb-1028-2.jpg`, `-3.jpg`, `-4.jpg`):

- "tags shouldnt be truncated. this is finder … unless they actually are really long and need
  to be truncated." Searcher's preview showed a "Yellow" tag as "Yell…"; Finder shows "Yellow"
  whole, then "Add Tag".
- "make sure we use same colors as finder." 0124 drew tags in `NSWorkspace.fileLabelColors`,
  "the system's label colors, which are Finder's older, lighter ones".

## What Finder draws, and how it was measured

The screenshots are 2× pixels. `fb-1028-4.jpg` carries the Studio Display profile and the other
two none; Searcher's own dots in `fb-1028-2.jpg` read as `fileLabelColors` in Display P3 (orange
(237, 187, 97) against (238, 185, 99)), so all three hold Display P3 values. Pixels were read
with `magick … txt:-` along a row or column through each shape.

- **Dots.** Finder's seven row-menu dots, in the middle: red (240, 110, 108), orange
  (244, 169, 104), yellow (248, 216, 104), green (131, 208, 131), blue (99, 158, 249), purple
  (201, 100, 226), grey (165, 164, 169). Its row dots measure the same: orange (244, 168, 102),
  yellow (248, 216, 104). Each is the matching system color in Display P3 (systemRed
  (235, 76, 70), systemOrange (240, 147, 67), systemYellow (247, 206, 70), systemGreen
  (101, 196, 102), systemBlue (59, 134, 247), systemPurple (187, 62, 217), systemGray
  (142, 142, 147)) lightened a fifth of the way to white, within 3 in every component. The fill
  is opaque: the yellow dot on the blue selection reads as it does on white.
- **Rims.** The outermost ring of each menu dot reads as the system color itself: red
  (235, 77, 74), orange (235, 147, 75), purple (186, 68, 216). On a row it is half a point wide.
- **Selected row.** Finder's dot on the selected row is a 10-point circle with a 1-point white
  outline, pixel for pixel the shape Searcher draws; only the color differed (Searcher's yellow
  (235, 224, 104)).
- **Label numbers.** 0121's mapping is Finder's: 6 Red, 7 Orange, 5 Yellow, 2 Green, 4 Blue,
  3 Purple, 1 Gray, the order of `NSWorkspace.fileLabels`.
- **Pills.** Finder's "Yellow" pill fills at (250, 224, 139) on white; the "Orange" pill of
  `tags-finder-row-dots-and-preview-pills.jpg` at (247, 188, 137). Both are their system color
  at 63% over white. (0124 read the orange pill as (246, 197, 156); a column through it reads
  (247, 188, 137).) The "Yellow" pill is 42 × 14 points, the name starting about 4.5 points in.
  Searcher's was 44 × 16, the name starting 7.5 points in.

## Why "Yellow" was cut

`TagPillView` sized the pill from its label's `intrinsicContentSize`: "Yellow" at 11 points
reported 33.5 points. The label's cell draws the name 2 points in from each side and needs
37.3 points (`cellSize`) to show it whole, so the 34-point label truncated it. The padding of 5
across and 1 down, added to that, made the pill 44 × 16: about Finder's width, but with the
name cut and further in.

## Decision

- **A pill is as wide as its cell needs.** `TagPillView.fittingSize` measures the label's
  `cell.cellSize`, and pads it 2 points across and none down, so the name sits 4 points from
  the pill's edge and "Yellow" makes a 42 × 14 pill, as Finder's. A pill wider than the preview
  is narrowed to the preview's width, on a row of its own, and only that one truncates, as 0124
  laid them out (`aPillShowsItsWholeNameUnlessItIsWiderThanThePreview`,
  `aPillWidenedToItsNameShowsItWhole`).
- **The tag colors are the system colors.** `NSColor.tagLabel(_:)`, still the one place the
  colors come from, maps the labels to `systemGray`, `systemGreen`, `systemPurple`,
  `systemBlue`, `systemYellow`, `systemRed` and `systemOrange`
  (`eachTagsColorIsTheSystemColorFinderDrawsItIn`). They are dynamic, so dark mode takes their
  dark variants.
- **A dot's fill** is `NSColor.tagLabelDot(_:)`: the tag's color lightened by
  `tagDotLightening`, a fifth of the way to white, in Display P3, worked out for the appearance
  it is drawn in, so it stays dynamic (`aDotsFillFollowsTheAppearance`). Each label's is made
  once, so a dot's fill compares equal to itself. A row's dot drawn in light mode comes within
  4 of Finder's in every component (`aRowsDotIsFilledAsFindersIs`). The row menu's dots and the
  main menu's dot images take the same fill.
- **A dot's rim** is the tag's color, where 0124 drew the fill 20% darker; Finder's rim reads as
  the system color. A row dot's rim stays half a point, a menu dot's one point, and a row dot on
  an emphasized selection keeps its 1-point white outline in place of the rim.
- **A pill's fill** is the tag's color at 63% (`TagPillView.fillAlpha`, was 65%), which over
  white comes within 2 of both Finder pills measured (`aPillOverWhiteIsFilledAsFindersIs`). The
  name stays in the label color, a tag without a color on `quaternaryLabelColor`.

## Alternatives considered

- **Keep `fileLabelColors`** — rejected: they are the older, lighter palette; red's dot was 19
  greener than Finder's.
- **Dots in the plain system color** — rejected: Finder's measure a fifth lighter than it, in
  every one of the seven.
- **Lighten with `NSColor.blended(withFraction:of:)`** — rejected: it blends in a calibrated RGB
  space, not the Display P3 the fit was measured in, and resolves the appearance once, when
  called, so the dot would not follow a change to dark mode.
- **Keep the label's intrinsic size and add 2 points of slack** — rejected: it hides the
  cell's padding in a magic number; the cell's own size is the measure of what it draws.

## Consequences

Tags look like Finder's in light mode: the seven dots and the pills within a few units of the
screenshots. Dark mode is not measured: the dots use the dark system colors lightened the same
way, and the pills those colors at 63% over the dark preview, which keeps white names readable.
A system color Apple changes in a later macOS moves the tags with it, as Finder's do;
`aRowsDotIsFilledAsFindersIs` would then fail and need Finder measured again.

**To check by hand:** dark mode against Finder: a row's dot, the selected row's dot, the row
menu's dots and the preview's pills, especially yellow's white name on its pill; a pill for a
tag without a color; a long tag name in a narrow preview.
