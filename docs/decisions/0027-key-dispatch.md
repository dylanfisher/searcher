# 0027. Key dispatch: menus and pane keys both run commands through the registry

- **Date:** 2026-10-21
- **Status:** accepted

## Context

M1.1 adds the main menu. Until now a key reached a command only through
`ListingTableView.keyDown` ([0021](0021-one-pane-window.md)). AppKit offers a key to the main menu
before the first responder's `keyDown`, so with a menu in place both paths must agree on what a
chord means. Text fields, such as M1.5's Go to folder field, need Cmd-A, Cmd-C and Cmd-V to edit
their text, even after a step binds those chords to file commands.

## Decision

Nothing but the registry turns a key into a command. A key reaches the registry by one of two
routes:

- **Menu items.** `MainMenuBuilder` builds every main menu from lists of `CommandID`s and
  AppKit's standard actions. A command item's key equivalent is its command's first chord,
  converted by `KeyChord+NSEvent`. Its action, `runMenuCommand(_:)`, has no target, so AppKit
  sends it to the focused pane's `ListingTableView`, which runs the command on that pane. With no
  table in the responder chain, AppKit disables the item. A menu listing an unregistered
  `CommandID` fails to build with an error naming it, and the app stops at launch.
- **Pane keys.** A key the menu doesn't take reaches `ListingTableView.keyDown`, which looks up
  the chord as before. This is how a command's other chords (Cmd-O for Open) work. A chord
  with Command, Control or Option that no command takes beeps through the table's injected
  `beep`, and doesn't reach `NSTableView`, whose key bindings would move the table's selection
  behind the pane's back (Ctrl-N is Move Down). Plain and Shift-only keys still go to `super`.

Standard items (About, Hide, Hide Others, Quit, Minimize, Zoom, Close Window, and Edit's Undo,
Redo, Cut, Copy, Paste and Select All) send AppKit's own selectors with no target. Their chords
are `KeyChord`s too, so no key equivalent literal exists outside `MainMenuBuilder`.

**Text fields keep their editing keys.** While a text field is first responder, its field
editor is the first responder, and the Edit items' actions reach it before anything else. The
table isn't in the field editor's responder chain, so no command runs. Because of this, a
command may share an Edit item's chord. When the table has focus, Select All runs the command
bound to Cmd-A, or beeps when there is none, and `NSTableView`'s own select-all never runs.
Copy, Cut and Paste are disabled there, since the table doesn't implement them, so their keys
fall through to the registry in `keyDown`. Undo and Redo don't: with the table focused they
reach `NSWindow`'s `undo:` and `redo:`, which use the window's undo manager, the one the field
editor records into, so M4.11 has to route them when it binds Cmd-Z. A command on the chord of an app or window item
(Cmd-Q, Cmd-H, Opt-Cmd-H, Cmd-M, Cmd-W) fails the build: the menu would take the key first.

A menu with no items is left out of the menu bar, so File and View appear once a step gives
them commands. A Dock click with no window open opens one on the home folder. A window's
controller is released when the window closes, which stops its pane's folder monitor.

## Alternatives considered

- **Catch keys in the window (`sendEvent`, a local event monitor) and look them up there** —
  rejected: it would run before the field editor and take Cmd-A, Cmd-C and Cmd-V from text
  fields, and it would duplicate the responder chain AppKit already walks.
- **Menu items targeting a command runner object** — rejected: the runner would have to track
  the focused pane itself. The responder chain already knows which table has focus, and disables
  items when none does.
- **Show the File and View menus empty** — rejected: an empty menu looks broken.
- **Let `NSTableView` handle Select All** — rejected: it selects every row in the table without
  the pane knowing, so the pane and the table disagree about the selection.

## Consequences

A command's menu item shows only its first chord; the order of `Command.chords` decides which.
A user shortcut set in System Settings' App Shortcuts replaces a menu item's key equivalent by
title. The pane's `keyDown` still knows the registry chord, so both keys work. A step that binds
Cmd-W to Close Pane (`tmp/behavior.md`) replaces Window's standard Close Window item with that
command. Shifted punctuation (Cmd-Shift-.) as a menu key equivalent is untested; the step that
binds one checks that AppKit matches it.
