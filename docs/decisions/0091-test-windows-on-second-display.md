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
  `SecondDisplay.orderFront`. `PaneLayoutViewTests` already picks the second display itself.
- **`SecondDisplay` in `TestSupport`.** `placed(_:on:)` moves a frame that overlaps the main display
  to the same offset on the second one, keeps its size (shrunk to fit), and leaves it inside the
  display's visible frame. A frame clear of the main display and a single display are unchanged.
  `orderFront` moves the window first, then uses `orderFrontRegardless`, so it is never key and
  the app is not activated, and nothing flashes on the main display.
- **No global hook.** Swizzling `NSWindow` or observing `didBecomeVisible` would catch windows a
  future test adds, but the observer moves a window after it appears, and a swizzle changes the
  code under test. A new test that shows a window uses `SecondDisplay.orderFront`.
- **Outside the tests.** `scripts/bench --ui` already puts its windows on the second display.
  `scripts/dev` launches the app, which opens its windows where the user last left them; agents
  don't run it.
