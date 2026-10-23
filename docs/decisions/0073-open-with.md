# 0073. Open With

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M4.11b asks for an Open With submenu in the File menu and the row context menu, listing the apps
Finder lists for the selection, the default first, from a cache built off the main actor per file
type. Asking Launch Services for apps can block, and reading each app's bundle ID and name reads
the disk, so neither may run on the main thread (B10). The plan doesn't say what a menu opened
before its type's list is built shows, which app is the default for a mixed selection, how the
menus reach the cache, or what Other… shows.

## Decision

- **Per type, not per file.** `SystemActions` lists the apps for a `UTType`
  (`NSWorkspace.urlsForApplications(toOpen:)` and `urlForApplication(toOpen:)` with a type), and
  `OpenWith` keys its cache by type. A selection's types are its rows' kinds, which the listing
  already holds, so opening the menu reads no file. A test checks that the type's list matches
  what Launch Services lists for a `.txt`, `.png` and `.mp3` file.
- **One build per type, kept for the life of the app.** `OpenWith` runs each type's lookup once
  on a global queue, reads each app's bundle ID and display name there, and keeps the result.
  Callers waiting on the same type share one build. The first build of each type is logged
  under the `openWith` category with its time in ms, for B10.
- **Order.** Each type's list puts the default app's copy first, then Launch Services' order,
  keeping the first copy per bundle ID. For several types the menu lists the apps in every
  type's list. The default app leads, marked "(default)" as Finder marks it, only when every type
  has the same default; the rest follow by name (`localizedStandardCompare`). Names drop ".app",
  which the display name keeps when Finder shows every extension.
- **Loading.** The submenu is filled in `menuNeedsUpdate(_:)` each time it opens. From the cache
  it fills at once. Otherwise it shows a disabled "Loading…" and Other…, starts the build, and
  replaces the items when it lands. The main queue runs during menu tracking, so the apps appear
  in the open menu. A fill that lands after the menu was filled again is dropped.
- **On and off.** The Open With item has an action of its own that AppKit never sends, so its
  target can turn it off while nothing is selected or the window has no cache, as Finder does.
- **Where it acts.** The context menu's item reads the clicked table; the File menu's reads the
  key window's first responder. Each table asks its pane view controller, which hands back the
  command pane (the focused column's in column view) and the cache from its `WindowLink`. The
  cache lives in `WorkspaceWindows`, beside the clipboard and the undo history; a window the UI
  bench opens has none.
- **Other…** shows an `NSOpenPanel` on /Applications that takes only apps, and opens the
  selection with the one chosen. Tests pass a chooser that shows no panel.
- **No undo.** Opening files in an app changes nothing on disk, so it records nothing
  ([0072](0072-undo.md)).

## Alternatives considered

- **Per file URL** (`urlsForApplications(toOpen: URL)`) — rejected: it reads each file, and a
  per-file list can't be cached per type. It honors a single file's own default app, set with
  Get Info's "Open with" on that file only; the type's list doesn't.
- **Building the whole menu once and keeping it** — rejected: it would go stale with the
  selection, and AppKit already asks for the items each time.
- **Waiting for the list before showing the menu** — rejected: it blocks the main thread for the
  first build of each type.
- **The first type's default for a mixed selection** — rejected: it would mark an app "default"
  for files it doesn't open by default.

## Consequences

An app installed while Searcher runs shows in Open With after a relaunch, since nothing clears
the cache. Symbolic links have the symbolic link type, so Open With on a link lists the apps for
links, not for its target. The menu shows no app icons: reading them is file-system work, and an
`NSImage` can't cross from the build queue to the main actor in Swift 6 without a copy.

## Amendment: icons, versions and App Store… (M4.16)

The menu now matches Finder's on macOS 26. This replaces the "Order" point's dedupe and names,
and the last sentence of Consequences.

- **Each app is read through `SystemActions.application(at:)`,** so tests describe apps without
  reading the disk. The real one reads the bundle ID, `CFBundleShortVersionString` and
  `FileManager.displayName` in Browser (`OpenWith.App(readingBundleAt:icon:)`), and asks Quick
  Look (`QLThumbnailGenerator`, `.icon`) for the icon at 16 points, 2x, as a `CGImage`, which
  crosses to the main actor where an `NSImage` can't. `NSWorkspace.icon(forFile:)` is the usual
  call, but it reads the bundle from Interface, which `scripts/arch` denies; Quick Look draws
  the icon in its own process, 20–40 ms per app. The apps of a type are read at once in a task
  group after Launch Services lists them, and the result is cached with the list, so the menu
  still opens from the cache (B10). The `openWith` log time now covers the reads and icons. An
  icon Quick Look can't make is logged and the item shows none.
- **One entry per bundle ID and version,** not per bundle ID: Finder lists each version of
  Google Chrome for Testing that `@puppeteer/browsers` installs. Copies of one version keep the
  first, the default's copy first. URLs that differ only in spelling are read once.
- **Names are the display name as is,** ".app" included when Finder shows every extension, as
  Finder's menu shows them.
- **Secondary text.** When two listed apps share a name, each shows its version after the name,
  and the default shows "(default)", both in `secondaryLabelColor` through the item's
  attributed title. The rest sort by name, then version (`localizedStandardCompare`).
- **App Store…** sits above Other… after a separator, as in Finder. It opens
  `macappstore://?action=search&term=<extensions>`, the selection's types' file extensions
  sorted and joined by spaces, through `SystemActions.openURL`. Finder's own lookup URL isn't
  public; `action=search&term=` is the form the App Store app's own links use.
