# 0032. Quick Look: Space through the registry, the list controls the panel, items by row

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M1.9 adds Quick Look: Space opens the system panel on the selection, ↑ and ↓ while it's open
move the list's selection and the preview follows, and Space or Escape closes it. Every key
goes through the command registry ([0027](0027-key-dispatch.md)), but the panel is
`QLPreviewPanel`, which Browser can't import. The selection can be provisional, and `members`
traps until it settles ([0029](0029-row-movement.md)). Cmd-A on W2 selects 100k entries, and the
main thread must not do per-entry work for it (B10). iCloud files can be dataless
([0030](0030-not-downloaded-badge.md)).

## Decision

- **Command.** `ViewCommands.toggleQuickLook`, "Quick Look", is bound to Space. Its binding calls
  `CommandContext.toggleQuickLook`, a closure Interface supplies when it builds the context in
  `PaneViewController`. A context built without one traps if the command runs, so Bench and the
  Browser tests, which never run it, build contexts as before.
- **Toggle.** `QuickLookController.toggle` closes the panel if it's open, beeps through the
  table's `beep` when nothing is selected, and otherwise opens the panel with
  `makeKeyAndOrderFront`.
- **Panel control.** `ListingViewController` accepts panel control in the responder chain, so
  the panel takes its data source and delegate, the pane's `QuickLookController`, from the list
  in the key or main window.
- **Keys in the panel.** The panel is the key window while it shows, so keys reach its delegate.
  `handle` looks the chord up in the table's registry and runs the command on the pane, as the
  table's `keyDown` does: ↓ runs Select Next Row, Space runs Quick Look and closes the panel. A
  key no command takes, such as Escape, goes back to the panel, which closes on Escape.
- **Items.** The items are the selection's rows in the listing shown, in row order, which is
  display order. An item is a URL built from the folder's path and the entry's name, with
  `isDirectory` from the entry's type, so it makes no file-system call. URLs are built only
  when the panel asks for an item, and the panel asks for the one it shows and its neighbors, so
  Select All over 100k entries costs the same as one entry. The `n`th item walks the index set's
  ranges, one range after Cmd-A.
- **The preview follows.** Each pane change refreshes the items. The panel reloads when the
  folder, the selected rows or the name of the item shown changed, so a folder change patch every
  0.1 s during a download doesn't reload the preview. It shows the cursor's entry, or the first
  item when the cursor isn't selected.
- **Provisional selections wait.** A provisional selection knows only the rows near the cursor.
  The controller keeps the items it had, or none, until the pane settles the selection off the
  main thread and reports the change. Every other selection's rows are exact, settled or not, so
  `members` is never read. Nothing is settled on the main thread.

## Alternatives considered

- **Quick Look on `SystemActions`** — rejected: it would add a method to every implementation,
  Bench's included, and the panel has to find the list through the responder chain anyway.
- **Settle a provisional selection on the main thread, as `Pane.openSelection` does** — rejected:
  a settle walks every entry, about 33 ms on W2, and while the panel is open a move can follow a
  patch on every key repeat. The pane settles it within a few frames.
- **Send the panel's keys to the table's `keyDown`** — rejected: unbound plain keys would reach
  `NSTableView`, and Escape would never get back to the panel.
- **Build every item's URL when the selection changes** — rejected: 100k URLs on the main thread
  for Cmd-A, of which the panel shows one.
- **A View menu item with Space as its key equivalent** — not added: a menu item takes its key
  before the first responder's `keyDown`, so Space could stop reaching text fields and
  type-to-select. That is unchecked. File now has a Quick Look item without one
  ([0060](0060-menu-items-for-every-command.md)).

## Consequences

The panel reads the files it previews. Previewing a dataless iCloud file downloads it, as it
does in Finder; that happens only on an explicit Space, never from browsing. A folder shows its
icon and details. The panel's own buttons, such as Open with, are the system's; the controller
never opens a file itself. A key the registry binds works in the panel even when the list has no
focus, so Cmd-↓ in the panel opens the selection. The panel is checked by hand: tests use a
stand-in for it and never show one. B6 with the panel open is measured in M1.13.

There is one panel per app, and each pane's list has its own controller. Once M3 splits a
window into panes, the panel can belong to another pane's list: `toggle` asks only whether the
panel is open, so Space in one pane closes a panel another pane filled, and which list controls
it follows the responder chain as focus moves. M3 decides whether Space there should hand the
panel over instead.
