# 0087. Palette window: an Open Quickly panel over the key window, off commands greyed

- **Date:** 2026-10-24
- **Status:** accepted

## Context

M5a.7 puts the palette model ([0085](0085-palette-ranking.md)) on screen. Cmd-K opens it over the
key window; typing ranks commands, saved workspaces, visited folders, the folders open panes show
and a typed path, with the matched letters bold and each command's chord; ↑ and ↓ move, Return
runs, Esc closes. No step counted folder visits yet, so the folder source had nothing to rank.
Recursive search and Spotlight are a separate feature (M5b.3) and stay out.

## Decision

- **Cmd-K, titled Open Quickly…, in the Go menu.** No command had Cmd-K. Xcode's Open Quickly is
  the closest macOS precedent for a panel that jumps to places and runs things, so the item takes
  its name; it sits under Go to Folder…, since most of what it lists are places. Finder's Cmd-K
  (Connect to Server) has no counterpart here.
- **A panel over the window, not a sheet.** An `NSPanel` with its title bar hidden, a child of
  the window it opened over, centered on it near its top, as Open Quickly sits over its window. A
  field with a magnifying glass on top, then rows: the kind's icon (Finder's folder icon, the
  sidebar's window symbol for a workspace, ⌘ for a command), the title with matched letters bold,
  the detail in secondary text, and a command's first chord right-aligned as a menu draws it
  (⌃⌥⇧⌘ order). The selection uses the system accent colour while the field has the keys, as
  Spotlight's does. Colours are the system's label colours, so light and dark both follow
  the appearance. A sheet would block the window and look like a question
  ([0076](0076-dialogs.md)).
- **Keys.** The field keeps the keys; ↑, ↓, Page Up and Page Down move the selection, Return
  (or Option- or Shift-Return) or a click runs the selected row, Esc closes. Closing gives the
  keys back to whatever had them when the palette opened (the pane's table, the sidebar or the
  filter field), as Xcode's Open Quickly does; the palette closes before an item runs, so the
  item runs from there. It closes when it loses the keys, as Spotlight does. Cmd-K again closes
  it, and so does Cmd-W, as in Open Quickly: the panel takes those chords as key equivalents
  before the menu bar, whose command items are off while the panel has the keys. Any other
  Command key the field doesn't use does nothing, without a beep. Cmd-A and the other editing
  keys reach the field's editor through the Edit menu.
- **Commands that can never run from the palette are left out**, in one set,
  `CommandSource.unlisted`: Open in New Tab (it needs a clicked folder), Open Quickly itself,
  and the row keys, which move a selection the palette covers.
- **Off commands are listed greyed and don't run.** Return on one beeps. The macOS menu search
  in the Help menu lists an item that is off greyed rather than hiding it, and that is the system's
  own command search; hiding would make a command seem missing when the window's state turns it
  off (Back at the start of the history). Xcode's Open Quickly and Spotlight list no commands, so
  they don't decide it.
- **Commands run on the focused pane's table**, as their key would, through its registry, so a
  chord shown is the one that works now, and the command's own check runs again when it runs.
  Folders open in the focused pane; saved workspaces open through
  `WorkspaceWindows.open(savedWorkspace:)`, the sidebar's path.
- **Folder visits.** `FolderVisits`, one per app, counts a visit each time a pane's location
  changes (navigation, Back and Forward, column view following its focused column) and once for
  each new pane: a new window, tab or split. A restored pane counts only where it goes next: it
  shows what it showed before, and counting it would add a visit to every restored folder on
  every launch. `WorkspaceWindows` gives it to
  the panes it makes; panes made from those share it. The stored history is read off the main
  actor beside the session's read and is not waited for: visits counted before it arrives are
  added to it, and nothing is saved until then, so a launch can't write over it. Saves go through
  `WorkspaceStore.saveFolderHistory`, which delays and writes off the main actor.

## Alternatives considered

- **Leave off commands out**, as VS Code's palette does with commands whose condition fails —
  rejected: the system's own command search shows them, and an item that vanishes and comes back
  with the window's state reads as a bug.
- **A borderless panel** — rejected: a titled panel with a hidden title bar gets the system's
  rounded corners and shadow and can take the keys without a subclass.
- **Count visits in `WorkspaceWindows`** — rejected: the pane is where a location commits, and
  every path to a new folder goes through it.
- **Wait for the stored history before opening windows** — rejected: B1 has no room for a second
  read on the launch path, and the visits made before it lands are few.

## Consequences

Arrowing through column view counts a
visit per folder entered, which ranks folders browsed that way higher than ones opened once from
a list; frecency's decay bounds it. B11 end to end (key → frame with results, 50k candidates) is
the UI bench's `palette` scenario, over synthetic folders shaped like W3's package tree, since the
app can't read the bench's W3 fixture list. VoiceOver reads the field's label and each row's
title, kind, chord and whether it is unavailable; a pass with VoiceOver on is left to Dylan.

## Update 2026-10-24: Spotlight's look

Dylan asked for the blurred, rounded look of Spotlight's window. The panel is now borderless
(`.borderless`, with `canBecomeKey` overridden so the field still takes the keys), non-opaque with
a clear background and a window shadow. The content is an `NSVisualEffectView` with material
`.popover`, blending `.behindWindow` and state `.active`, its layer rounded to 20 pt with the
continuous curve. `.popover` is the material the system uses for popovers and follows light and dark
appearance; `.hudWindow` is always dark and `.menu` is tuned for menu rows. The state is `.active`
because the panel is only ever shown with the keys, and a blur that went flat when the panel lost
them would flash as it closes. Nothing overrides the view's handling of Reduce Transparency or
Increase Contrast. The field is 26 pt, as Spotlight's is large. This replaces the "borderless panel
— rejected" alternative above: the system corners and shadow of a titled panel come with a title
bar's chrome, which is what the blur had to sit under.
