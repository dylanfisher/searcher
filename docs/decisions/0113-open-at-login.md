# 0113. Open at login, read from the system's login items

- **Date:** 2026-10-26
- **Status:** accepted

## Context

Dylan, 2026-10-26: "lets also make it so searcher can be configured to auto start on computer
boot". The Settings window ([0106](0106-primary-and-alternate-shortcuts.md)) had one pane,
Shortcuts. macOS 13 added `SMAppService` in the ServiceManagement framework; its `mainApp`
registers the running app as a login item, listed under System Settings ▸ General ▸ Login
Items, where the user can also remove it. The app targets macOS 14.

`SMAppService.mainApp.status` is `.notRegistered`, `.enabled`, `.requiresApproval` or
`.notFound`. Checked on this machine (macOS 26) with a probe that only reads the status: a bare
executable, as `swift run` starts, reads `.notFound`, and so does an ad hoc signed `.app` bundle
with a bundle identifier that was never registered. `.notFound` doesn't mean "can't register".

## Decision

- **A General pane**, first in the Settings toolbar and the one the window opens on, holds an
  "Open at login" checkbox, off until the user checks it. Each pane has its own size; switching
  keeps the window's top edge where it was.
- **The system is the one source of truth.** No preference stores the setting. `GeneralSettings`
  reads `status` when the model is made, each time the Settings window shows, and each time the
  app becomes active, so a removal in System Settings shows when the user comes back. After
  register or unregister it reads the status again, whether or not the call threw.
- **What the checkbox shows.** On for `.enabled` and `.requiresApproval`; off for
  `.notRegistered` and `.notFound`. `.requiresApproval` adds a note and an "Open Login Items
  Settings" button that calls `SMAppService.openSystemSettingsLoginItems()`. Checking calls
  `register()`, unchecking `unregister()`.
- **Errors are shown, not swallowed.** A thrown error shows in red under the checkbox with the
  system's description ("Searcher couldn't be added to the login items: …"), is announced to
  VoiceOver as the Shortcuts pane's notices are, and stays until OK.
- **Outside an app bundle** the checkbox is off and disabled, with the note "Open at login is
  available only when Searcher runs from its app bundle." The test is
  `Bundle.main.bundleIdentifier != nil` and a bundle path ending in `.app`, since the status
  can't tell a bare executable from a bundle not yet registered. `scripts/bundle`, which
  `scripts/dev` runs, copies `Sources/Searcher/Info.plist` with `CFBundleIdentifier`
  `com.dylanfisher.searcher` into `.build/Searcher.app`, so the dev bundle can register. The
  item points at that bundle's path; a rebuild replaces the bundle at the same path.
- **Behind a protocol.** `LoginItem` is what the model calls; `MainAppLoginItem` wraps
  `SMAppService.mainApp`, and `SettingsWindowController(settings:)` makes it. Tests pass a stub
  through the internal initializer, so no test registers this machine's app.
- **A login launch is a normal launch.** Apple documents no argument or flag that marks a
  `mainApp` login launch, and Searcher looks for none. Searcher restores the last
  session's windows as at any launch ([0080](0080-restore-at-launch.md)) and activates. There
  is no hidden or background launch mode.
- **No new dependency.** ServiceManagement is a system framework, linked by its `import`.
- **No command or menu item.** The checkbox is the only way in.

## Alternatives considered

- **A stored preference mirrored into the system** — rejected: the user can remove the item in
  System Settings, and the stored copy would then say on while it is off.
- **Disable the checkbox on `.notFound`** — rejected: a bundle that was never registered also
  reads `.notFound`, so it would never be enabled.
- **A hidden launch at login** (no windows until the Dock icon is clicked) — rejected for now:
  it needs a way to tell a login launch apart, which `SMAppService` doesn't give, and Dylan
  asked only for the app to start.
- **`SMLoginItemSetEnabled` with a helper app**, or a LaunchAgent plist — rejected: the helper
  route is deprecated since macOS 13, and both are more parts than `mainApp`.

## Consequences

- `status`, `register()` and `unregister()` are synchronous calls to a system daemon on the main
  thread, made only when Settings shows, the app activates after Settings was made, or the
  checkbox changes. They read no file.
- A bundle signed ad hoc changes its code hash on each rebuild; whether the login item survives
  a rebuild of the dev bundle has to be checked by hand.
- The Settings window now opens on General rather than Shortcuts.
