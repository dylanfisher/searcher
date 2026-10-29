# 0137. Default file viewer: other apps' Show in Finder opens Searcher, through NSFileViewer

- **Date:** 2026-10-29
- **Status:** accepted

## Context

Dylan, 2026-10-29: "is it possible so that in chrome when it says show in finder in a download we
can make it say show in searcher? and/or override our default "finder" app to open/reveal things
in searcher?", then "add that as an opt-in setting, ideally it undoes itself if you uninstall
searcher", and "the setting should also have button to restore default".

Chrome's "Show in Finder" title is Chrome's own string, so Searcher can't change it. Where the
reveal goes can change. AppKit's `NSWorkspace.activateFileViewerSelecting(_:)` and
`selectFile(_:inFileViewerRootedAtPath:)` read the undocumented `NSFileViewer` key, a bundle ID,
through `UserDefaults.standard`. Path Finder and ForkLift set it in the global domain to become the
file viewer. Checked on this machine (macOS 26) with a probe app and a sender that reveals:

- **The key is read on each call**, from the caller's own defaults: the argument domain, then the
  app's domain, then the global domain.
- **A reveal reaches the viewer as a plain `aevt`/`odoc` (open documents) event** naming the
  revealed item, a file or a folder, never its parent. AppKit sends no `misc`/`mvis` event. The
  app sees it as `application(_:open:)`, the same as Open With or a drop on its Dock icon; nothing
  in the event marks it as a reveal.
- **A viewer that can't be found falls back to Finder.** With the key naming an ID that no app
  has, or an app in the Trash, the caller logs `Finder replacement <id> not found; "defaults
  delete -g NSFileViewer" to remove log` and Finder reveals the item.
- **The key in the caller's argument domain wins.** Setting `NSFileViewer = com.apple.finder` in
  `UserDefaults.standard`'s argument domain with `setVolatileDomain(_:forName:)`, in memory only,
  sends that process's reveals to Finder with no log, while the global key names another app.

## Decision

- **The setting.** The General pane, under Open at login: a checkbox, "Use Searcher instead of
  Finder to show files", off until the user checks it, with the note "Other apps' Show in Finder
  opens Searcher. Finder itself, the Dock and some apps still use Finder." Beside it, a "Use
  Default" button, the name the pane's config section already gives the same idea.
- **The global key is the one source of truth.** No preference stores the setting, as for Open at
  login ([0113](0113-open-at-login.md)). The model reads `NSFileViewer` in the global domain
  through `CFPreferencesCopyValue` with `kCFPreferencesAnyApplication`,
  `kCFPreferencesCurrentUser` and `kCFPreferencesAnyHost`, never through `UserDefaults.standard`,
  which Searcher overrides (below). It reads when the model is made, each time the Settings window
  shows, each time the app becomes active, and after every change, so a change made by
  `defaults` or another app shows.
- **What the controls show.** The checkbox is on when the key is Searcher's bundle ID. With the key
  set to another ID, the checkbox is off and a note names the app ("Other apps' Show in Finder
  opens Path Finder.") or, with no app for the ID, says "Other apps' Show in Finder names
  “<id>”, which isn't installed, so Finder shows files." Use Default is on whenever the key is set,
  to any ID, and off when it isn't.
- **Changing it.** Checking writes Searcher's bundle ID to the global key and synchronizes the
  global domain. Unchecking removes the key only if it is still Searcher's ID. Use Default removes
  the key whatever it names, which hands reveals back to Finder after another viewer or a stale
  ID. A write that fails (`CFPreferencesAppSynchronize` returns false) shows in red under the
  checkbox ("The file viewer couldn't be changed: macOS didn't save the change."), is announced
  to VoiceOver, and stays until OK, as Open at login's errors do. Unchecking reads the key again
  first, so an ID another app wrote since the pane last read it stays. The General pane grows to
  420 points tall, room for every note and problem it can show at once.
- **Outside an app bundle** the checkbox is off and disabled, with the note "Searcher can show
  other apps' files only when it runs from its app bundle." The test is the one
  `MainAppLoginItem.isAvailable` makes. Use Default stays usable, since removing the key needs no
  bundle.
- **Behind a protocol.** `FileViewerSetting` is what the model calls; `GlobalFileViewerSetting`
  reads and writes the global key, and `SettingsWindowController(settings:)` makes it. Tests pass
  a stub, so no test changes the machine's file viewer.
- **Searcher's own Reveal in Finder still goes to Finder.** At launch, before any window opens,
  the app delegate adds `NSFileViewer = com.apple.finder` to `UserDefaults.standard`'s argument
  domain, keeping what the domain already holds. Without it Searcher's reveal, and the config
  file's Reveal in Finder, would come back to Searcher as an open event. It runs in
  `applicationWillFinishLaunching`, in a bench launch too: a bench reveals nothing, and the
  in-memory key changes no other default.
- **Receiving a reveal.** `application(_:open:)` hands the URLs to `WorkspaceWindows`. Each item is
  shown selected in its parent folder, a folder too, as Finder's reveal selects a folder rather
  than opening it. Items in one folder share one window with all of them selected; items in
  several folders get a window each. A window whose focused pane already shows that folder is
  brought to the front and selects the items, as Finder reuses its window; otherwise a new window
  opens at the folder. The app activates. Folder and names come from the URL's path, with no
  stat on the main thread. Of several windows showing the folder, the most recently active one
  is used, and its pane lists the folder again, so a download that landed since the last listing
  is there to select. Revealing `/` shows it with nothing selected; a URL that isn't a file's is
  logged and skipped. Selecting several names on arrival takes `Pane.navigate(to:selection:)`
  and a `Pane` initializer with a `Selection`, in Browser, beside the single-name ones.
- **A reveal that launches Searcher.** The launch restores the last session as at any launch
  ([0080](0080-restore-at-launch.md)), then shows the reveal's windows in front. With nothing to
  restore, the reveal's windows take the place of the home window, which doesn't open. A reveal
  that arrives while the restore runs waits for it. AppKit hands over a launch's open event
  before `applicationDidFinishLaunching`, so saves are held for the restore from
  `applicationWillFinishLaunching` on, and `WorkspaceWindows` keeps a reveal that comes while
  they are held until `restore` runs.
- **Uninstalling undoes it.** Nothing runs when an app is deleted, and Searcher doesn't need to:
  once the app is gone or in the Trash, AppKit can't find the ID and every reveal goes to Finder.
  The key stays in the global domain, harmless, with a log line per reveal; reinstalling Searcher
  turns the setting back on. Use Default, or `defaults delete -g NSFileViewer`, removes it.
- **Folders opened, not revealed,** stay Finder's. Making Searcher the default app for
  `public.folder` is a separate change.
- **No new dependency.** CoreFoundation's preferences API ships with the system.

## Alternatives considered

- **A stored preference mirrored into the key** — rejected for the reason 0113 gives: another app,
  or `defaults`, changes the key, and the stored copy would then disagree with it.
- **Open a folder that arrives in `application(_:open:)`** instead of selecting it in its parent —
  rejected: the event can't tell a reveal from Open With, and with the setting on most of these
  events are reveals. Finder's reveal of a folder selects it, and so does Searcher's.
- **Write `com.apple.finder` to Searcher's own persistent domain** for its own reveals — rejected:
  the argument domain does the same in memory and leaves nothing in the app's preferences file.
- **Ask Finder to reveal with an Apple Event** for Searcher's own reveals — rejected: it needs
  Automation permission, a prompt the reveal doesn't need today.
- **Remove the key on uninstall** with a login item or a launch agent that watches the bundle —
  rejected: the agent's plist sits in the bundle, so it goes with the app and never runs, and the
  fallback to Finder already makes a stale key harmless.
- **Change the title of Chrome's menu item** — not possible from outside Chrome.

## Consequences

- Reading and writing the key are synchronous calls to `cfprefsd` on the main thread, made only
  when Settings shows, the app activates, or a control changes; they read no file, as 0113's
  status calls don't.
- `NSFileViewer` is undocumented. A macOS update can stop honoring it; the setting then does
  nothing and reveals stay in Finder.
- Launch Services resolves `com.dylanfisher.searcher` to whichever bundle it registered last,
  which on a development machine can be `.build/bench/Searcher.app` rather than the dev bundle.
- Checked by hand: Chrome's Show in Finder on a download, with Chrome already running when the
  setting changes, and Searcher both running and quit; Use Default with another ID in the key;
  Searcher's own Reveal in Finder with the setting on.
