# 0122. Shortcuts in the config file

- **Date:** 2026-10-27
- **Status:** accepted
- **Amends:** [0106](0106-primary-and-alternate-shortcuts.md), where it says how stored
  shortcuts are normalized and that they are read from `UserDefaults` only, and
  [0120](0120-config-format.md), where it says shortcuts wait for M5b.2.

## Context

M5b.2 lets the config file ([0120](0120-config-format.md)) set shortcuts. The plan's step was
written before shortcuts could be set in the app, with `bind = <chord> <command>` and
`unbind = <chord>` lines. Since then each command has two slots, a primary and an alternate,
that `Settings.shortcuts` overrides one by one ([0106](0106-primary-and-alternate-shortcuts.md)),
and every other setting reads as the app's value, then the file's, then its default (0120).
A line that starts with the chord can't say which slot it fills, so the file follows the slots.

## Decision

- **One line per slot.** `shortcut.<command ID>.<slot> = <chord>`, as
  `shortcut.window.showPalette.alternate = cmd+shift+o`, or `= none` to take the slot's chord
  away. The key is the command's ID as the registry spells it, with its dots and capitals, so
  the file, `defaults write` (0106) and the code name a command one way; it breaks 0120's
  lowercase-with-dashes rule for keys, which is the preferences' own. The slot is what follows
  the last dot, since IDs have dots. The chord is `KeyChord.stored`'s spelling, the one
  `Settings.shortcuts` stores; a chord with a `#` in it goes in double quotes. The prefix is
  matched in the parser's second step, before the preference lookup, as 0120 planned.
- **Layers, per slot.** A slot takes the app's override (`Settings.shortcuts`), then the file's
  (`Settings.configShortcuts`), then its default or the Commander preset's alternate.
  `KeyBindings` takes both as `overrides` and `fileOverrides` and stays the one place that
  combines them. Claims go in that order too: the fixed Edit chords, then the app's chords, then
  the file's, then the defaults. A file chord a default or the preset gives another command
  takes it, and the other command loses it, as for the app's chords in 0106; an app chord a
  file line gives another command takes it from that command. Both are listed in
  `KeyBindings.dropped` and logged under `keys`, not errors: the file can't know what the app
  holds, and a default that moves later would otherwise turn a good file bad.
- **Errors, by line, and the file is not applied** (0120). The parser finds an unknown command
  ID, a slot other than `primary` or `alternate` (or none), a chord `KeyChord(stored:)` refuses,
  a slot set twice, and one chord on two lines, for two commands or both slots of one; that
  error names the earlier line. Chords are compared as written: `cmd+shift+.` and `cmd+shift+>`
  are two chords to the parser, as to the registry (0106's Consequences).
- **The menus' rules, checked by the watcher.** A reserved chord (`MainMenuBuilder.reservedChords`),
  an Edit item's fixed chord on another command or slot, and a fixed primary changed or set to
  `none` (`MainMenuBuilder.fixedChords`) are errors on their lines too. Browser can't see the
  menus, so the app passes both sets to `ConfigWatcher`, which checks each read with
  `ConfigLoad.checked(reserved:fixed:)` after `ConfigParser.parse`. The check is
  `KeyBindings.refusals(of:reserved:fixed:)`, the same rules `KeyBindings` applies to the app's
  overrides, which drop such a chord quietly instead. So a file with one of them is refused
  whole, off the main thread, and the banner names the line, as for any other error. A fixed
  primary set to its own chord changes nothing and is no error.
- **Setting the file's value in the app clears the app's.** As for preferences (0120), a slot
  the app sets to what it would have without the override, the file's slot or else the
  default, is stored as no override, so the slot follows the file again. Only the commands whose
  override changes are compared, so an override set while the file said something else keeps
  overriding it after the file changes. Reading the stored shortcuts at launch no longer drops a
  slot equal to its default: the file isn't read yet, and that slot may be what overrides it.
- **A file change doesn't normalize the stored overrides again.** A read of the file never
  writes `UserDefaults`, as for preferences (0120): the file can change many times a minute
  while it is edited, and a half-written save would otherwise rewrite, and lose, the app's
  overrides. So "no change" has two stored forms: no entry, and an entry that the file's change
  left equal to what the slot has without it, such as `.removed` on a slot with no default after
  the file line that gave it a chord is deleted. That entry does nothing until the file sets the
  slot again, when it overrides it again. Reset and Reset All are on only for an override that
  changes a command's slots now (`Settings.shortcutOverrideChangesSlots(of:)`), so neither
  stays on for a row that shows no change. The entry is normalized away the next time that
  command's override is set.
- **The Shortcuts pane.** A slot whose chord, or lack of one, is the file's says so under the
  row ("The config file sets the alternate shortcut."). A slot the app sets to other than the
  file's is listed under its row as the General pane lists a preference: "Searcher has ⌃⌥⌘L as
  the alternate; the config file has ⌃⌥⌘J." with Use Config File Value, which removes the app's
  slot (`Settings.useConfigShortcut(for:)`). A slot the file doesn't set isn't listed; Reset is
  for that. Reset removes the command's app overrides, which gives it the file's slots and then
  its defaults; Reset All removes every app override the same way. Neither writes the file.
- **Template.** After the preferences, a note on the shortcut lines, then every command's two
  slots commented out at their code defaults, `none` for a slot with none, each command under
  its title, in a block per command set in `AppCommands.sets` order. The menus' grouping
  (`MainMenuBuilder.commandsByMenu`) is in Interface, and Open Config File writes the template
  from Browser, so the sets stand in for it. A preset alternate isn't a default, so it reads
  `none`; uncommenting that line takes the F-key away.
- **Live reload.** A read that changes the file's shortcuts tells the settings' observers once.
  `PaneViewController.keyBindings(for:)` keys its cache on the file's shortcuts too, so the
  bindings are made again once, at the next read after the change, and every table, the
  sidebar's `passKey`, the menus' `showChords`, the context menus, the palette and the Settings
  window take the new ones. A key press compares the cached settings and does no other work.

## Alternatives considered

- **`bind = <chord> <command>` and `unbind = <chord>`** — rejected: the slot model is per
  command, a chord-first line can't say which slot it fills, and `unbind` of a default would
  be a second way to write `none`.
- **Lowercase-dashed keys, as `shortcut.window.show-palette.alternate`** — rejected: a second
  spelling of every command ID, to keep in step with the registry by hand or by a conversion
  that a later ID could break.
- **Check reserved and fixed chords when the bindings are made, on the main actor** — rejected:
  by then the file has been applied, so the error couldn't keep it from applying, and the
  banner would need a second source of errors.
- **The file's shortcuts as errors when a default has the chord** — rejected: see Layers.
- **Reset All back to the defaults, past the file** — rejected: the app never writes the file,
  so it can't set the file's slots aside; Reset All undoes what the app holds, which is what it
  did before.

## Consequences

The template is a few hundred lines longer, one comment and two lines per command. A command
renamed in the code makes its lines in a user's file an error that names the old ID, where the
app's stored override of it is dropped quietly (0106): the file is the user's text, and a line
that does nothing should say so.

Browser's tests check the menus' rules with chords they give, and the app passes the real ones
from `MainMenuBuilder`; a test of the walk over every command through the file passes no rules,
as `KeyBindingsTests.everyCommandCanBeRebound` does.
