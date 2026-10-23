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
  child on the way down. Clicking the pane's own folder does nothing.
- **Truncation.** The segments between the ends shrink first, the one nearest the root first,
  each down to 32 points; then the root, then the pane's folder. Titles truncate in the middle. A
  row too long even then is clipped at the bar's edge.
- **Layout.** The list and the bar are pinned with constraints, the bar 24 points tall along the
  pane's bottom. The pane's container starts at zero size, where frames set for autoresizing
  can't hold the bar's height, and the list ended up 24 points taller than the pane.

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

## Consequences

Every load, including a reload and a monitor's re-list, costs one more call off the main thread.
A folder that fails to list moves the bar to it, so the bar and the error line agree. Until the
first update of a pane lands, the bar is empty.

## Open questions for Dylan

- **The root under `/Volumes`.** The root segment names the startup volume for every folder, so a
  folder on an external disk shows "Macintosh HD › Volumes › Backup › …". Finder starts that bar at
  "Backup". Changing it means starting the segments at the folder's volume root and reading that
  volume's name.
- **The bar while a folder loads.** The bar stays on the folder the pane left until the new
  folder's first rows, or its error, arrive. For a slow share that can be a while, with an empty
  list under the old path. The other choice is to move the bar at navigation, beside the spinner.
