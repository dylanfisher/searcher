# 0060. Every command has a menu item; pane focus and move keys follow Origami

- **Date:** 2026-10-22
- **Status:** accepted

## Context

After M3, the tiling keys, the dual-pane keys, Quick Look, Open in New Tab, the column keys and
the row keys could only be run from the keyboard. `tmp/behavior.md` now asks for every command
to have a main menu item, keyed or not, so a user can find each command and its key in the menu
bar. A menu item's key equivalent reaches AppKit before the first responder's `keyDown`
([0027](0027-key-dispatch.md)), so a plain key there would be taken from text fields and
type-to-select, as Tab would ([0054](0054-tabs-in-window.md)) and Space would
([0032](0032-quick-look.md)). Dylan also asked for the focus and move keys of his Origami setup in
Sublime Text.

## Decision

- **Every registered command has an item.** `everyRegisteredCommandHasAMenuItem` builds the menus
  and fails, naming each command, when a command in `AppCommands.bindings` has no item. Edit's
  Select All counts for the command on its chord (Cmd-A), since the table runs that command for
  it.
- **Placement.**
  - File: Quick Look, beside Reveal in Finder, where Finder puts it.
  - Edit: a Selection submenu after Select All with the row keys: next, previous, first and last
    row, 10 rows down and up, page down and up, extend down and up.
  - Go: Open in New Tab and Open in Other Pane after Open; Into Selected Folder and To Parent
    Column (column view); Same Folder in Other Pane before Go to Folder.
  - Window: Split Right and Split Down; then Focus Other Pane, Focus Pane, Move Pane and Resize
    Pane (submenus, one item per arrow), Zoom Pane, Unzoom Pane and Equalize Panes. iTerm keeps its split
    pane selection and resizing in the Window menu, and Window already held Focus Other Pane,
    Close Pane and the window moves.
  - `MainMenuBuilder.Item` gets a `submenu` case, which builds a nested `Menu` the same way.
- **Help.** The last menu is Help, with no items: AppKit adds its menu search field to the app's
  help menu, so `install` sets `NSApp.helpMenu`. There is no help book, so there is no Searcher
  Help item. The bar keeps this one empty menu (`isFilledBySystem`); every other empty menu is
  left out.
- **No key equivalent for keys text fields use.** A command whose key has no Command, Control or
  Option (Tab, Space, the arrows, Shift-arrows, the page keys) is listed with
  `commandWithoutKey`; `eachCommandItemsKeyEquivalentIsItsCommandsFirstChord` fails if one of
  them shows a key equivalent. The table still gets the key in `keyDown`. The whole Selection
  submenu is keyless, Opt- and Ctrl-Shift-arrows, Home and End included: text fields move by
  those keys too, and every row key repeat would otherwise go through the menu bar's key
  equivalent search first. Every other command shows its first chord.
- **Pane keys.** Focus Pane is Cmd-Opt-Shift-arrow, which Move Pane had. Move Pane is
  Ctrl-Opt-Shift-arrow, which no command or standard item used. Cmd-Opt-arrow is unbound, and
  a test keeps it so.

## Alternatives considered

- **A Pane menu for the tiling commands** — rejected: Window already held the pane items, and a
  seventh menu adds one more place to look.
- **Flat lists of the twelve directional items** — rejected: three submenus keep Window short,
  and each family's arrows read together.
- **A second Select All item for the selection command** — rejected: two items with one title,
  and the existing one already runs the command from the table.
- **Key equivalents on Opt- and Ctrl-Shift-arrows, Home and End** — rejected: see above. The menu
  shows no key for them; the table still runs them.

## Consequences

A new command fails the test until it is placed in a menu. Items for commands that need the
table stay off while the keys are in the filter field, the path bar or the tab strip, as before
([0054](0054-tabs-in-window.md)). Ctrl-Opt-Shift-arrow reaches the app only while no system
shortcut takes it; Mission Control's Ctrl-arrows have no Option or Shift.
