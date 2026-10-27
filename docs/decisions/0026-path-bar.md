# 0026. Path bar: the root volume's name rides each listing update, and the bar moves with the rows

- **Date:** 2026-10-21
- **Status:** accepted

## Context

M1.6 adds a path bar under each pane's list. Its root segment shows a volume name, which takes a
file-system call, and `PathBarView` must make none. The plan says the name comes from the listing
and is read off the main thread, and that the bar updates on the frame the new folder's first rows
appear. `Listing`, `DirectoryLister` and `DirectoryEntry` belong to M1.3 in the same wave, so the
name can't ride in the listing itself.

## Decision

- **Which volume.** The bar's segments are `Location.ancestors`, which start at `/`, so the root
  segment names the volume mounted at `/` ("Macintosh HD"), wherever the folder is. A folder under
  `/Volumes/Backup` shows "Macintosh HD › Volumes › Backup › …".
- **Where it's read.** `ListingService` calls its `rootVolumeName` closure on the load's worker
  thread, once per load, before listing. The default, `ListingService.readRootVolumeName`, calls
  `FileManager.displayName(atPath: "/")` and traps on the main thread. Every `ListingUpdate` case
  carries the name as `rootVolumeName`, and `Pane.rootVolumeName` keeps the last one. The name is
  `rootVolumeName` everywhere because it is always the volume at `/`, never the listed folder's.
  `displayName` doesn't throw, so a load never fails for the name.
- **Injected.** The closure is a `ListingService` init parameter rather than a `Lister`
  requirement, since `Lister` lives in `DirectoryLister.swift`, which M1.3 owns. Tests pass a fixed
  or changing name.
- **When the bar moves.** `PaneViewController` shows the pane's location in the bar on any change
  whose state isn't `loading`: the first batch, the full listing, or a failure. While a new
  folder loads, the bar keeps the folder the pane left. The rows and the bar change in the same
  `paneDidChange`, so one frame shows both.
- **Clicks.** Clicking a folder above the pane's runs `Pane.navigate(to:selecting:)` with the
  child on the way down. Clicking the pane's own folder does nothing. (Amended 2026-10-25: in
  column view a click on a folder whose column shows moves the focus to that column instead,
  keeping every column; see [0103](0103-column-trail-from-the-root.md). Amended again the same
  day: the columns right of it close, and the click is a step of the history.)
- **Truncation.** The segments between the ends shrink first, the one nearest the root first,
  each down to 32 points; then the root, then the pane's folder. Titles truncate in the middle. A
  row too long even then is clipped at the bar's edge.
- **A truncated segment under the mouse** gets its full width, as in Finder's path bar: the bar
  lays the row out again with that segment shrinking last, so the others give way in the usual
  order and the row's ends stay put. The change is instant, with no animation. Which segment is
  hovered is read from the mouse's x against the row with nothing expanded, never against the
  row as it lies, so it depends on the mouse alone. Reading it from the expanded row oscillated:
  expanding one segment could move the next under a still mouse, AppKit then reported the mouse
  over that one, it expanded, and the first came back. Each segment still truncated after layout
  has its full name as a tooltip, and the others have none (added 2026-10-23, M4.23).
- **Inset.** The row starts 9 points from the bar's sides, `Margin.standard`, which the
  operations panel's rows share, so the first folder lines up with their text (2026-10-23; it
  was 6 points).
- **Layout.** The list and the bar are pinned with constraints, the bar 28 points tall along the
  pane's bottom (24 until 2026-10-23, when Dylan asked for more room above and below). The pane's
  container starts at zero size, where frames set for autoresizing can't hold the bar's height,
  and the list ended up 24 points taller than the pane.
- **Separators.** Each is the SF Symbol `chevron.right` at the titles' point size, small scale,
  in the tertiary label color, as in Finder's path bar. It is centered on the middle of a capital
  letter, measured from the first segment's baseline, rather than on the bar, so it stays level
  with the titles at any font size. Its frame is the one around its intrinsic size taken as an
  alignment rect. The "›" text labels this replaced were given their intrinsic width, 5 points,
  while the glyph needs 9 with the label's insets, so the glyph was clipped.
- **Hover.** The bar has one tracking area (entered, exited and moved, in the visible rect,
  while the app is active; until 2026-10-23 each segment had its own) and keeps which segment
  the mouse is over; a separator or the ends hover none. The bar draws a rounded
  `quaternaryLabelColor` rectangle behind that segment, 2 points taller than the title above and
  below, as Finder does; the color is darker grey in light mode and lighter in dark. Segments keep
  their intrinsic height, because a taller button draws its title lower than its baseline offset
  reports, which put the chevrons off center. A new path clears the highlight.
- **The focused pane's bar** (added 2026-10-26, BC.1b, at Dylan's request) draws its titles in
  `labelColor`, and every other bar in `secondaryLabelColor`, as Finder and Xcode set the active
  tab's title apart. The chevrons stay tertiary, and nothing else changes: no weight, size or
  background, so the titles keep their widths and nothing moves as the focus does. The focused
  pane is `Layout.focused`, and the window marks it where it rings it, so the bar follows every
  focus change the ring does: a click, Tab, the palette, Cmd-U, a closed pane. It is emphasized
  - **with one pane too**, since that pane is the one the commands act on, and a split then
    leaves the bar the user was reading as it was;
  - **with the keys in the sidebar**, though the ring hides then: the pane is still the one the
    commands act on and the keys go back to, as Finder's window keeps its target while its
    sidebar has the keys;
  - **only while the window is key or main**: `Workspace.isActive`, which the window sets as it
    gains and loses key, or the window being main, which it tracks as it gains and loses main.
    The palette's panel and a sheet take the keys but can't become main, so the window under
    them stays main and keeps its bar dark (BC.1c, at Dylan's request: with key alone, every bar
    went grey while Cmd-K was open). Another window or app coming forward takes main too, and
    then every bar here shows unemphasized. `isActive` keeps meaning key, since it also orders
    the loads and the panes' focus.

## Alternatives considered

- **Add the name to `Listing`** — rejected for now: M1.3 owns `Listing.swift` in this wave.
- **Read it once per process** — rejected: a renamed volume would keep its old name until
  relaunch, and the read costs about 20 µs a load (1,000 calls in a loop, built with `swiftc -O`,
  on Dylan's Mac) against B2's 50 ms.
- **The name of the folder's own volume** — rejected: the root segment is `/`, and labeling it
  "Backup" for a folder on that volume would put the wrong name over `/`.
- **Move the bar at navigation** — rejected: for a slow folder the bar would name a folder whose
  rows aren't there, which is what the plan rules out.
- **Route the click through the command registry** — not yet: no command takes a target folder.
  M3.6a's open-in-new-tab command is where a path command would join the registry.
- **A short animation for the expanding segment** — rejected: the segments would slide under the
  mouse, and a tooltip or click mid-slide lands on a moving target.
- **A tooltip only, no expanding** — rejected: Finder expands, and the tooltip waits for the
  hover delay.
- **The focused pane's folder in semibold** — rejected: a bolder title is wider, so the row
  would shift as the focus moves.
- **A tinted background for the focused bar** — rejected: new chrome, and the ring already marks
  the pane in a split.
- **A tracking area per segment** — replaced: each segment reported the mouse against its
  current frame, so an expansion that moved a neighbor under the mouse handed the hover on.

## Consequences

Every load, including a reload and a monitor's re-list, costs one more call off the main thread.
A folder that fails to list moves the bar to it, so the bar and the error line agree. Until the
first update of a pane lands, the bar is empty.

A segment hovers while the mouse is inside its span in the unexpanded row, so the highlight can
change while the mouse is still over the expanded segment's text, at the point where the next
segment's unexpanded span starts.

## Open questions for Dylan

- **The root under `/Volumes`.** The root segment names the startup volume for every folder, so a
  folder on an external disk shows "Macintosh HD › Volumes › Backup › …". Finder starts that bar at
  "Backup". Changing it means starting the segments at the folder's volume root and reading that
  volume's name.
- **The bar while a folder loads.** The bar stays on the folder the pane left until the new
  folder's first rows, or its error, arrive. For a slow share that can be a while, with an empty
  list under the old path. The other choice is to move the bar at navigation, beside the spinner.
