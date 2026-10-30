# 0139. The tab strip draws Finder's track, pill and hover close buttons

- **Date:** 2026-10-29
- **Status:** accepted
- **Amends:** [0054](0054-tabs-in-window.md) (the strip was a segmented control with no close
  buttons), [0110](0110-interaction-states.md) (the strip's tabs take their own fills)

## Context

Dylan, 2026-10-29: "tab style should look closer to finder (no blue highlight, x shows up on
hover and then gets darker when hovering over the x itself, more rounded pills with a bit of gap
around them so you can see darker background area)". `tmp/shots/fb-1029c-1.jpg` is Finder's
macOS 26 strip at 2×.

The strip was an `NSSegmentedControl`, which on macOS 26 fills the selected segment with the
accent color in a key window. It had no way to close a tab with the mouse.

Measured from the shot, in points: the track is 28 tall with fully rounded ends (radius 14), a
flat gray about 0.90 white on the window's 0.98 to 1.0. Each tab is a segment of the track. The
selected tab's pill is 2 inside its segment on every side, 24 tall and fully rounded (radius
12), about 0.97 white, with a faint shadow under its bottom edge and a light top edge. The
unselected title is a mid gray, the selected one darker, both centered. Nothing is blue.

## Decision

- **Searcher draws the strip.** `TabStripView` draws the track, `secondarySystemFill`, 28
  points tall, 6 points in from each side of the strip, which is 34 points tall. The tabs split
  the track into equal segments. Each is a `TabButton`.
- **The selected tab** draws a pill 2 points inside its segment, radius 12, in `controlColor`
  with a shadow of `shadowColor` at 15%, 1.5 blur, 0.5 down. Its title is `labelColor`; the
  others' are `secondaryLabelColor`. Titles are the 13 pt system font, centered, one line,
  truncated at the tail.
- **No accent color.** Every color is a system gray or `controlColor`, which the system
  resolves for light and dark. In light the track comes to 0.90 over Finder's 0.98 window, the
  shot's gray, and the pill to 1.0, a little lighter than the shot's 0.97: no system color is a
  gray that light in light and lighter than the track in dark. In dark the track is about 0.24
  over a 0.17 window and the pill 0.43 over the track.
- **The close button** is a round `HoverButton`, 16 points, with a 9 pt semibold `xmark` in
  `secondaryLabelColor`, 6 points from the tab's leading edge, where Finder's tab puts it. It is
  hidden until the mouse is over its tab, on any tab, selected or not. Under the mouse it fills
  a `quaternaryLabelColor` circle and while pressed a `tertiaryLabelColor` one, 0110's fills. It
  closes its tab through `Workspace.close`, and the window drops the tab's views as it does
  after Close Tab. While the button shows, the title keeps its room at both ends, so it stays
  centered; while it is hidden the title takes the segment but 10 points each side, so narrow
  tabs keep their titles, as Finder's do. A tab reads its hover again from the mouse's location
  whenever the strip lays it out: closing a tab moves the others under the mouse with no
  mouseExited, which would leave a close button on a tab the mouse had left.
- **States.** An unselected tab fills its pill's shape with `quinaryLabelColor` under the mouse
  and `quaternaryLabelColor` while pressed: on the track, 0110's `quaternaryLabelColor` hover
  fill would be as dark as the track twice over, where Finder's hover is a slight darkening. The
  selected tab keeps its pill under the mouse and while pressed, as Finder's does, and shows its
  close button. Each tab and close button is an `NSButton`, so it joins the key loop only with
  keyboard navigation on, as Finder's tabs do, and the system draws the focus ring, in the pill's
  shape for a tab and a circle for the close button. Neither is ever disabled: the strip shows
  only with two tabs or more, and each can be selected and closed.
- **VoiceOver** reads the strip as a tab group named "Tabs" and each tab as a radio button
  titled with its folder, selected or not, with a Close Tab action. The tab view is the element,
  not its cell, which AppKit would expose as an unnamed button. The close button is not an
  element: it shows only on hover, and the Close Tab action does what it does.

## Alternatives considered

- **Restyle the segmented control** — rejected: it draws the accent on the selected segment and
  has no per-segment hover or close button.
- **AppKit's window tabs** — rejected by 0054: they can't hold a split tree per tab.
- **A fixed light and dark pair of colors** for the track and pill — rejected: the label colors
  and `controlColor` already resolve for both appearances and for Increase Contrast.

## Consequences

The strip is 6 points taller, so the rows under it start 6 points lower. Tabs can't be dragged to
reorder them, and there is no New Tab button in the strip; neither was there before. Tests check
the track and pill geometry, that every color is a gray in both appearances and none is an accent
color, the fills and the close button's visibility and states, and closing a tab from the strip
in a window. The look, the shadow and the dark appearance need a check by eye.
