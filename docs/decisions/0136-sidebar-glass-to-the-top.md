# 0136. The sidebar's glass runs to the window's top: the unified toolbar again

- **Date:** 2026-10-29
- **Status:** accepted
- **Amends:** [0128](0128-finder-window-chrome.md) (the sidebar's look),
  [0133](0133-flat-translucent-bars.md) (the compact toolbar)

## Context

Dylan, 2026-10-29, once the app was linked against SDK 27
([0134](0134-link-against-the-current-sdk.md)): "make sure we match finder's sidebar look where
the 3 window buttons in top left are inside the sidebar glass card. make sure our colors match
finder's (the sidebar background color is different)". His screenshots: Finder
(`tmp/shots/fb-1029-2.jpg`), Searcher (`tmp/shots/fb-1029-3.jpg`), both stacked
(`fb-1029-1.jpg`). Finder's sidebar is a glass card inset 8 points from the window's edges that
runs up to the window's top, with the window buttons in it. Searcher's card started below the
toolbar, and the buttons sat in a near-white band above it.

Measured in windows on the second display, by the frame of the sidebar's glass view
(`NSGlassEffectView`) in the window:

- **The compact toolbar keeps the sidebar out of the toolbar's band.** With
  `toolbarStyle = .unifiedCompact` AppKit stops the card at the bar's bottom, 40 points below the
  window's top, in Searcher's window and in a bare split view controller with nothing of ours in
  it. With `.unified` or `.automatic` the card runs to 8 points below the top, its inset at the
  leading edge too. `.expanded`, a transparent title bar and a hidden title don't help.
  `allowsFullHeightLayout` was already on.
- **A sidebar collapsed when the window takes its split view gets a band over its glass.** AppKit
  then gives the sidebar's part of the toolbar a hard scroll edge effect: a content background
  material over the top of the card, which stays after the sidebar shows. A new window's sidebar
  is hidden unless the last window's shows (`WorkspaceWindows.open`), so this was the usual case
  after Show Sidebar. A sidebar collapsed after the window took the split view doesn't get it.
- **The card's fill is the system's.** In the two shots of active windows (`fb-1029-2`,
  `fb-1029-3`) Finder's card and Searcher's are the same grey, 249 of 255. In `fb-1029-1`
  Searcher's window is active and Finder's isn't, the likely reason the two cards differ there.
  The near-white band above Searcher's card was the toolbar's band. Nothing of ours draws on the
  card: the sidebar's scroll view draws no background, and the source list draws none.

## Decision

- **The toolbar is `.unified` again**, the style Finder's window has on macOS 26: 52 points tall
  as 0128 measured it, with the sidebar's glass running up beside the toolbar's items and the
  window buttons in it. The compact style of 0133 is dropped: it stops the sidebar below the bar,
  and Finder's bar is the unified one's height. Dylan chose the full-height sidebar over the
  compact bar on 2026-10-29. Everything else of 0133 stays: the banner, the
  tab strip and the status bar as the panes' accessories, the rows under the toolbar, and each
  pane's `topCover`, which reads the taller bar from the safe area.
- **The sidebar is collapsed after the window takes the split view**, not before, so a sidebar
  that shows later has no band over its glass.
- **With the toolbar hidden** the window has a title bar only, and AppKit starts the card below
  it, as in any window with no toolbar. Finder with its toolbar hidden wasn't checked (0128).
- **States.** The toolbar's items and the sidebar's rows keep the system's hover, pressed, focus
  and disabled looks; nothing here draws a control.

## Alternatives considered

- **Keep the compact bar and draw a glass card of our own up to the top** — rejected: a copy of
  the system's card would drift from it ([0128](0128-finder-window-chrome.md)), and AppKit would
  still lay the sidebar's content out below the bar.
- **Remove the band by finding and hiding AppKit's scroll edge view** — rejected: it is a private
  view; collapsing later avoids it with public calls.

## Consequences

- The toolbar is 12 points taller than 0133's, so the panes' rows start 12 points lower while it
  shows. Hidden, the title bar is 32 points in either style, as 0133 measured.
- Tests check the card's frame against the window's top and the window buttons, with the toolbar
  shown and hidden, and that no material lies in the sidebar's part of the window after it shows.
  The look still needs a check by hand: the agent can't capture the screen.
- **Not changed: the rows' names.** In the two active shots Searcher's names draw pure black where
  Finder's draw a dark grey (about 26 of 255); the icons and the group headings match. The names
  are `labelColor` text fields in the source list, which AppKit draws with vibrancy; why the two
  differ couldn't be told without seeing the screen. **Dylan to compare by eye.**
