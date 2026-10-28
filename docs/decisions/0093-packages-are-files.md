# 0093. Packages are files

- **Date:** 2026-10-24
- **Status:** accepted

## Context

The lister reported every folder as `.directory`, packages included, so Open browsed into an app
or an RTFD document instead of opening it, Open in Other Pane showed its insides, and column view
gave it a column. Only the Kind column and the folders-first sort knew about packages, from the
extension. Finder treats a package as one file everywhere except Show Package Contents.

## Decision

- **The lister names packages.** `DirectoryEntry.FileType` has a `.package` case. A folder is a
  package by Finder's rule (`PackageRule`): its extension names a type that conforms to
  `com.apple.package`, or its Finder info has the bundle bit (`kHasBundle`). A test checks the
  rule against `URLResourceValues.isPackage`. `.framework`, `.lproj` and `.xcodeproj` without
  Xcode installed are folders, as in Finder.
- **Cheap signals only.** `getattrlistbulk` asks for `ATTR_CMN_FNDRINFO` with the other
  attributes, so the bundle bit costs no call. The extension is looked up once per process per
  extension, under a lock, and only for folders whose name has one and whose bundle bit is clear.
  A folder read alone (change watching, the firmlink and stat fallback) reads its Finder info
  with one `getattrlist`, only when the extension doesn't decide.
- **Open treats a package as a file.** Return, double-click and Cmd-↓ hand it to its app through
  `SystemActions.openFile`, as for any file. Open in Other Pane is off for it, as for a file
  (0047). Column view adds no column for it and shows the preview (0090), after the keys pause
  when keys selected it, as for a file (0094); → does nothing.
- **A link to a package opens as a file.** Homebrew links casks into /Applications, and Finder
  launches the app such a link points to. Before Open lists a link as a folder (`openLink`), the
  pane asks `DirectoryLister.isPackage(followingLinksAt:)` off the main thread (amended
  2026-10-24: on a `BlockingCallThread`, not a global dispatch queue, as
  [0038](0038-slow-volumes.md) requires of a call that can block on a share; see
  [0095](0095-preview-metadata.md)): it resolves the
  link with `realpath` and applies the rule to the target's own name and Finder info, since the
  link's name needn't have the extension. A link to a package goes to the system; any other
  link is listed as before, and a target that can't be read is left to that listing to report.
  Open in Other Pane on such a link opens nothing, as on a link to a file. Links still add no
  column and show no preview (0090). A navigation before the answer cancels the open, as it
  cancels a pending go. The check is a `realpath`, an `lstat` and at most one `getattrlist` per
  Open, so it isn't timed against the slow and offline states; a link onto a stalled share
  waits in that read rather than in the listing that would show the slow state.
- **Show Package Contents** (File menu and row context menu, after Open With, no key) browses
  into the one selected package as a folder: the pane moves into it, or in column view a column
  for it opens to the right at once, without the keys' pause, and takes the keys. That column
  stays while the package stays
  selected and goes when another row is selected. The item is there for every selection and
  turned off unless one package is selected, as every context-menu item is (0070); Finder hides
  it instead.
- **Sorting.** Finder's Folders First keeps packages with the files: an app sorts among the
  documents, not the folders. The kind of a package is never `.folder`, so `Listing` already
  sorts it with the files; a package with only the bundle bit has the kind "Package".
- **A package is still a folder on disk.** `FileType.isFolderOnDisk` covers both cases where the
  disk shape matters: folder sizes walk and show for packages, as Finder shows a package's size;
  a package's file URL ends in a slash, as Finder writes it; the size walker enters packages.
- **Drops.** Files dropped on an app's row open with that app (`SystemActions.open(_:
  withApplicationAt:)`), as in Finder, with the generic drag cursor. Finder only accepts types
  the app claims; asking Launch Services during a drag would block the main thread, so every
  file drop is taken and the app decides. Dropping an app on itself, or file promises on an app,
  is refused. A drop on any other package's row goes to the pane's folder, as on a file's row;
  nothing is moved into a package.
- **Go to folder.** The palette's path completion (`PathSource`) offers folders only, so it no
  longer offers packages; a package's path can still be typed in full.
- **Unchanged.** Type-select, hidden files and Quick Look (Space shows an app's Quick Look) go
  by name and selection, not type. Rename selects a package's name without its extension, as
  Finder does for a file.

## Measurements

A scratch benchmark listed a generated 100,000-entry folder (99,000 files, 1,000 folders, W2's
shape) with `getattrlistbulk` 20 times each way, alternating, release build, on a machine shared
with other builds: median 84–104 ms without `ATTR_CMN_FNDRINFO` and 75–86 ms with it, so no
measurable cost; the 32 extra bytes per entry take the 256 KB buffer from 31 to 43 calls, which
makes the first batch smaller, not later. `/Applications` (40 entries) listed in 0.020 ms
either way. The extension lookup adds a dictionary hit per folder with an extension. No budget
in performance.md is expected to move; `./scripts/bench` wasn't run (other builds were running).

## Alternatives considered

- **A `isPackage` flag beside `.directory`** — rejected: every `== .directory` check would need
  `&& !isPackage`, and a missed one browses into an app. A new case makes the compiler list every
  switch, and the checks that mean "on disk" say so with `isFolderOnDisk`.
- **`URLResourceValues.isPackage` per folder** — rejected: a resource-value read per folder off
  the bulk call, against B2/B5.
- **Hide Show Package Contents unless it applies** — not done: the context menu builder turns
  items off and never hides them; hiding needs a new item kind.

## Consequences

Stored listing caches from before this change list packages as folders until the folder is
listed again, which happens on the next visit. The column preview of an app shows the generic
application icon, not the app's own, until icons are read per file.

## Amendment: the color label (2026-10-27, TG.2)

The listing also takes the color label from the Finder info it reads, and reads the tags
attribute of an entry whose label isn't 0, for the row's tag dots. A folder or file read alone
reads its Finder info with one `getattrlist` for the label
([0124](0124-tags-in-rows-and-preview.md)).
