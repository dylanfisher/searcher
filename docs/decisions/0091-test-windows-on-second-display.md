# 0091. Test windows go on the second display

- **Date:** 2026-10-24
- **Status:** accepted

## Context

Agents run the Interface tests on the developer's Mac while he works. A test window at a frame in
global coordinates opens on the main display, where he is working.

## Decision

- **Few tests show a window, so the helper is explicit.** `WorkspaceWindows.showsWindows = false`
  keeps every controller unshown, sheets and the palette panel need a visible parent, and the Quick
  Look tests replace `openPanel`. The one test that orders a window in
  (`WorkspaceWindowsTests`, the sidebar follows the front window) now calls
  `SecondDisplay.orderFront`. `PaneLayoutViewTests` picks the second display itself when there is one and falls back to the main display with one; it only runs with `SEARCHER_LAYOUT_FIXTURE` set.
- **`SecondDisplay` in `TestSupport`.** `placed(_:on:)` moves a frame that overlaps the main display
  to the same offset on the second one, keeps its size (shrunk to fit), and leaves it inside the
  display's visible frame. A frame clear of the main display and a single display are unchanged.
  `orderFront` moves the window first, then uses `orderFrontRegardless`, so it is never key and
  the app is not activated, and nothing flashes on the main display.
- **`WindowGuard` enforces it.** A run-loop observer, installed when the test bundle loads as
  `BeepGuard` is, fails the run when a visible window (panels and the Quick Look panel included)
  overlaps the main display while a second display exists, naming its class and title. It checks
  once per run-loop pass, so a window ordered in and out with no pass between goes unseen.
- **No placement hook.** Swizzling `NSWindow` or observing `didBecomeVisible` would catch windows a
  future test adds, but the observer moves a window after it appears, and a swizzle changes the
  code under test. A new test that shows a window uses `SecondDisplay.orderFront`.
- **Outside the tests.** `scripts/bench --ui` already puts its windows on the second display.
  `scripts/dev` launches the app, which opens its windows where the user last left them; agents
  don't run it.
