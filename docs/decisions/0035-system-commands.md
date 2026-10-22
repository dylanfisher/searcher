# 0035. Copy path, reveal in Finder and open Terminal: through SystemActions, errors shown by Interface

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M1.10 adds Cmd-Opt-C (copy the selection's paths, or the folder's with nothing selected),
Cmd-Opt-R (reveal the selection in Finder) and Cmd-Opt-T (open Terminal at the pane's folder, the
app being a setting) (`tmp/behavior.md`). Browser can't reach the pasteboard or `NSWorkspace`, and
a command's `run` returns nothing, so a bundle ID with no installed app needs somewhere to fail.
The selection can be provisional ([0029](0029-row-movement.md)).

## Decision

- **Commands.** `SystemCommands` holds Copy Path, Reveal in Finder and Open Terminal Here.
  Each calls a method of the pane's `SystemActions`: `copyToPasteboard`, `revealInFinder` and
  `open(_:inAppWithBundleID:)`. Copy Path sits in the Edit menu after Copy, as Finder's Copy as
  Pathname does; the other two make the File menu.
- **What they act on.** The selection's rows in display order, as URLs built from the folder's
  path and each entry's name, with `isDirectory` from the entry's type, so no file-system call.
  Copy Path joins their paths with newlines, with none after the last, and doesn't escape a
  name that contains a newline, as Finder's Copy as Pathname doesn't. Hidden entries that the
  pane doesn't show have no row, so Select All never copies or reveals them. With nothing selected, or
  no rows yet, Copy Path and Reveal act on the pane's folder; Reveal then selects the folder in
  its parent's Finder window. Open Terminal Here always opens the pane's folder. A provisional
  selection is settled on the main thread first, as Open does.
- **The terminal app.** `Settings.terminalBundleID`, `com.apple.Terminal` by default, with the
  rules of [0031](0031-view-settings.md): a missing key reads as the default, a value that isn't
  a string is removed and reads as the default. No UI sets it yet.
- **Failing.** `WorkspaceSystemActions` looks the bundle ID up with
  `NSWorkspace.urlForApplication(withBundleIdentifier:)`. With no app it logs and presents
  `AppNotFound`, "There’s no app with the bundle ID “…”.", through `NSApp.presentError`, an
  app-modal alert. An error from the open itself is logged and presented the same way. Tests
  inject the lookup and the presenter, so nothing opens and no alert shows.
- **Main thread.** The pasteboard write, the lookup, `activateFileViewerSelecting` and
  `open(_:withApplicationAt:configuration:)` run on the main thread. None reads a file's type,
  which is why `openFile` moves off it.

## Alternatives considered

- **A throwing `SystemActions` method, with the command reporting the error** — rejected: a
  command has nowhere to show it without a new `CommandContext` closure, and the only real
  failure is in the workspace call, which Interface already owns.
- **Disable Reveal and Copy Path with nothing selected** — rejected: the behavior spec gives Copy
  Path the folder's path then, and revealing the folder is the same idea.
- **A sheet on the pane's window for the error** — not now: `WorkspaceSystemActions` knows no
  window. The app-modal alert names the bad ID, which is what the user needs.

## Consequences

Copy Path after Cmd-A on W2 builds 100k URLs on the main thread; it is an explicit command, not
measured. Whether `activateFileViewerSelecting` blocks on a slow share is unchecked. The
terminal app needs to open a folder handed to it as a document, as Terminal and iTerm do; one
that doesn't fails or ignores it. Dylan checks all three by hand; tests never touch Finder,
Terminal or the real pasteboard.
