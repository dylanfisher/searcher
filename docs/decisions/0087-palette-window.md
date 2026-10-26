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
  (⌃⌥⇧⌘ order). (Amended 2026-10-26: the first chord is the effective primary, the one the
  user's shortcuts give it, read from the focused table's registry, or the alternate when the
  user removed the primary; [0106](0106-primary-and-alternate-shortcuts.md).) The selection
  uses the system accent colour while the field has the keys, as Spotlight's does. Colours are the system's label colours, so light and dark both follow
  the appearance. A sheet would block the window and look like a question
  ([0076](0076-dialogs.md)). (Amended 2026-10-25, Dylan: "you should be able to move the cmd
  k/cmd p dialogs around anywhere on screen, separate from the window if possible (like
  spotlight). by default it shows up centered on screen". The panel is a window of its own, not
  a child of the window it opens over, so it moves without the window and the window moves
  without it; it is dragged by its background (`isMovableByWindowBackground`), the field and
  the rows keeping their clicks, as Spotlight is. A child that detached on a drag was rejected:
  it moves with its window until the first drag, two behaviors where Spotlight has one. Being
  its own window, it joins the space showing, a full-screen window's included
  (`.moveToActiveSpace`, `.fullScreenAuxiliary`). It opens on the screen of the window that
  opened it, centered across the visible area with its top a fifth of the way down, in the upper
  part where Spotlight opens. **Where it was dragged is remembered**, as Spotlight remembers,
  in `Settings.palettePlace` ([0031](0031-view-settings.md)), across relaunches: one place for
  both palettes, since they are one panel of one size, as Spotlight has one place. The place is
  kept relative to a screen, as the share of the room the panel leaves across and down its
  visible area, two numbers within 0 and 1, and is put on the screen of the window that opens
  the next palette. A stored place therefore always lands wholly on a current screen, a smaller
  one included, and there is no display to be disconnected: a place tied to a display would open
  the palette on another screen than the window being worked in, or need a fallback when that
  display is gone. A panel dragged partly past an edge is stored against that edge; one dragged
  off every screen clears the place. Stored data that isn't two numbers within 0 and 1 is
  removed and reads as no place, the default. The place is saved as the panel closes, only when
  it moved since it showed. The keys still go back to the window that opened it, and losing them
  still closes it.)
- **Keys.** The field keeps the keys; ↑, ↓, Page Up and Page Down move the selection, Return
  (or Option- or Shift-Return) or a click runs the selected row, Esc closes. Closing gives the
  keys back to whatever had them when the palette opened (the pane's table, the sidebar or the
  filter field), as Xcode's Open Quickly does; the palette closes before an item runs, so the
  item runs from there. It closes when it loses the keys, as Spotlight does. Cmd-K again closes
  it, and so does Cmd-W, as in Open Quickly: the panel takes those chords as key equivalents
  before the menu bar, whose command items are off while the panel has the keys. Any other
  Command key the field doesn't use does nothing, without a beep. Cmd-A and the other editing
  keys reach the field's editor through the Edit menu. (Amended 2026-10-25, Dylan: "add a cmd k
  alternative shortcut (keep both) as cmd+shift+p". Open Quickly has ⇧⌘P beside ⌘K, the key VS
  Code and Sublime Text open their command palette with, as Go to Item has ⇧⌘K beside ⌘P
  ([0101](0101-go-to-item.md)). No command had it: the app has no Print item. The menu shows
  ⌘K, the first chord, and ⇧⌘P closes the panel as ⌘K does, since the panel takes every chord
  of the command that opened it.) (Amended 2026-10-26, Dylan: "if a command window is open
  (cmd+k or cmd+p), pressing a keyboard shortcut for another command window should close that
  one and open the other". The panel also takes the chords of the other palette's command, Go
  to Item's in Open Quickly and Open Quickly's in Go to Item, each with its primary and
  alternate as the user's shortcuts give them, read from the focused table's registry at each
  key as the closing chords are. One closes the panel, which gives the keys back to whatever had
  them, and opens the other palette, which finds them there; so the second palette gives them
  back to the same place the first would have. The closing chords are checked first, and the
  registry refuses a chord two commands claim, so no chord does both.)
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
  `WorkspaceWindows.open(savedWorkspace:)`, the sidebar's path. (Amended 2026-10-26, Dylan:
  "after using cmd+k to go to a file or directory, always put focus back into that pane (if you
  were focused on sidebar it should focus on the pane where you just went to the new directory
  or file)". Once a chosen folder has opened, the focused pane, the one it opened in, takes the
  keys, even if the sidebar or the filter field had them; the filter is cleared by the
  navigation anyway. Its focus ring shows again, as when a Focus Pane command moves the keys out
  of the sidebar ([0089](0089-sidebar-key-routing.md)). A command or a saved workspace still
  gives the keys back to whatever had them; a command that moves them itself, such as Focus
  Other Pane or Filter, still does. Go to Item's rows do the same as folders
  ([0101](0101-go-to-item.md)).)
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
`.popover`, blending `.behindWindow` and state `.active`, rounded to 20 pt by a
resizable `maskImage`, so the blur and the window shadow follow the shape. `.popover` is the material the system uses for popovers and follows light and dark
appearance; `.hudWindow` is always dark and `.menu` is tuned for menu rows. The state is `.active`
because the panel is only ever shown with the keys, and a blur that went flat when the panel lost
them would flash as it closes. Nothing overrides the view's handling of Reduce Transparency or
Increase Contrast. The field is 26 pt, as Spotlight's is large. This replaces the "borderless panel
— rejected" alternative above: the system corners and shadow of a titled panel come with a title
bar's chrome, which is what the blur had to sit under.

## Update 2026-10-24: Liquid Glass

Dylan found the blur still didn't read as Spotlight's translucent glass. From macOS 26 the
backdrop is `NSGlassEffectView` (style `.regular`, `cornerRadius` 20, the palette's views as its
`contentView`), the system's own Liquid Glass; it rounds itself, so no mask image is needed there.
Before macOS 26 the `NSVisualEffectView` above stays, behind `#available`. The window stays
non-opaque and clear with its shadow, and nothing overrides the glass's handling of Reduce
Transparency or Increase Contrast. Nothing opaque sat between the blur and the desktop: the
window, field, table and scroll view were already clear. The flat look came from the material:
`.popover` is a heavy, nearly uniform blur with none of the glass's refraction or lensing. The scroll
view's clip view is now set to draw no background explicitly, so the list can't paint over the glass.

## Update 2026-10-25: no window shadow around the glass

Dylan saw a square, light rectangle around the rounded glass, with the corners filled. The window
server shapes a window's shadow from the alpha of the pixels the window drew. The masked blur
carried a `maskImage`, so its shadow was rounded; `NSGlassEffectView` is composited outside the
window's own pixels and has no such mask, so the shadow of the glass panel is the window's
rectangle, and it shows through the translucent glass. From macOS 26 the panel has no window
shadow (`hasShadow` false) and the glass draws its own edge; before 26 the masked blur keeps the
rounded shadow. The cause was inferred, not seen: screen capture isn't available to the agent that
built it, so the look needs a check on a real display. If the glass reads flat without a shadow,
the next option is a larger window with a layer shadow shaped to the rounded rectangle.
(Amended 2026-10-25, Dylan: "cmd k and cmd p dialog windows still has strange artifacts around
the corners ... we need the border color and dropshow, like spotlight". The inferred cause was
wrong. A test can capture its own windows (`CGWindowListCreateImage` with the window's number,
on the second display), and captures showed the shadow already rounded and no square while the
app was inactive. With `NSApplication.isActive` swapped to true in a throwaway test, so the
panel drew as key, the square appeared with the shadow off: the panel's own pixels outside its
rounded corners had alpha 0.06 at the top to 0.12 at the bottom, black, a fill over the whole
rectangle while the panel is active. None of the app's own views paints there (their layers have
no background), so it comes from the layers inside `NSGlassEffectView`. The content is now a view whose layer clips to the
rounded shape (`cornerRadius` 20, `masksToBounds`), holding the backdrop and, over it, a
hairline edge: a border one pixel wide, white at 60% in light mode and 20% in dark. With the
corners clear, the window shadow is back on (`hasShadow` true on every system) and the
captures show it following the rounded shape, with no square, over a red window in light and
dark mode and over the desktop. The clip applies before macOS 26 too, where the masked
blur was already rounded.)
