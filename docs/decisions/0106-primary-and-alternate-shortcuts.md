# 0106. Primary and alternate shortcuts the user can set

- **Date:** 2026-10-26
- **Status:** accepted

## Context

Dylan, 2026-10-26: "all shortcuts should have primary and alternate that can be set by user".
Each `Command` lists its default chords ([0010](0010-command-registry.md)); none has more than
two. The Commander F-key preset ([0070](0070-context-menus-and-services.md)) adds a third chord
to four commands. Menus show only the first chord, and every other chord reaches its command
only through the table's `keyDown`, the sidebar's `passKey`
([0089](0089-sidebar-key-routing.md)) and the palette's closing chords, so a second chord such
as Cmd-Shift-P doesn't work while a text field has the keys. There is no Settings window yet.

The work lands in three steps: SK.1a, the model and the registry (this record's first part);
SK.1b, the menus and the routing; SK.1c, the Settings window and the recorder.

## Decision

- **Two slots per command.** `Command.chords` holds the defaults, two at most (a precondition),
  read as `primary` and `alternate`. The menus show the primary.
- **What the user changes.** `ShortcutOverride` holds a `Slot` for each position: `.standard`
  (the default), `.removed`, or `.chord(KeyChord)`.
- **Stored shape.** `Settings.shortcuts`, under the key `shortcuts`, is
  `[String: [String: String]]`: command ID to `"primary"` and `"alternate"` to a chord's
  `KeyChord.stored` spelling, or `""` for a removed chord, for example
  `{"window.showPalette": {"alternate": "cmd+shift+o"}}`. A missing slot is the default.
  - "Default" has one stored form, no entry: a chord equal to the slot's default, or a removed
    slot with no default, becomes `.standard`, and an override with both slots `.standard` is
    left out. Resetting a command deletes its entry; resetting all deletes the key.
  - Normalizing compares against the code's defaults, not the preset: an alternate the user set
    to F5 stays stored while the preset is on, so it keeps F5 after the preset is turned off.
  - Data of another shape, or any override in it of another shape, removes the whole key, as
    for `favorites` ([0107](0107-sidebar-favorites.md)). An entry for an ID no command has
    removes only that entry: a renamed command is a change of the code, not bad data.
- **Stored spelling.** `KeyChord.stored` writes the modifiers held, in the order ctrl, opt,
  cmd, shift, then the key, joined by "+": `cmd+shift+k`, `cmd++`, `f5`, `pageup`.
  `KeyChord(stored:)` accepts only what `stored` writes, so each chord has one spelling.
- **The preset is a default alternate.** While `Settings.commanderFKeys` is on, F5 to F8 are the
  default alternates of the four commands in `FileCommands.commanderFKeys`, none of which has one
  of its own (a precondition, and a test). The user's alternate replaces it, and removing it
  stays stored though the slot has no code default.
- **One place combines them.** `KeyBindings` takes the commands, the preset, the overrides and
  the reserved chords, and gives each command's effective slots (`chords(of:)`) and one
  `CommandRegistry`, whose commands list the primary first. A removed primary leaves the
  alternate as the registry's first chord, so the menus show it. `AppCommands.keyBindings(settings:reserved:)`
  builds it for the app; `AppCommands.registry()` is the defaults alone.
- **Conflicts.** A key has one meaning (0010). The user's chord wins: when stored data gives a
  chord to one command that a default or the preset gives another, as after a default changes,
  the other command loses it. Two overrides with one chord keep the first command's, in
  `AppCommands.sets` order. What is lost is listed in `KeyBindings.dropped`, which
  `PaneViewController` logs. Stored data never makes it throw or trap; a clash between two
  defaults still throws, since that is a mistake in the code.
- **Reserved chords.** No command may have the chord of a standard item that isn't text editing
  (Quit, Hide, Hide Others, Minimize, Settings…): the item always takes the key first.
  `MainMenuBuilder.reservedChords` derives them from the menus, and `KeyBindings` drops one that
  stored data names.
- **Assigning.** `KeyBindings.assign(_:to:at:replacing:)` is the only rule for recording a chord:
  `.reserved`, `.taken(by:)` another command, or `.assigned` with the new overrides. It checks
  every chord a key press can mean (`KeyChord.candidates(for:)`), so the two spellings of a
  shifted punctuation key on AZERTY ([0031](0031-view-settings.md)) count as one key, and stores
  the last, the key's own character. With `replacing`, the other command's slot becomes
  `.removed`. A chord the same command has in its other slot moves.
- **Cached, never per key.** `PaneViewController.registry(for:)` makes the registry when the
  shortcuts or the preset change and keeps it; every table and the menus take that one.
- **Until the Settings window.** The keys follow shortcuts set with `defaults write` from the
  next launch. Each command's slots go in as a plist dictionary literal:

  ```
  defaults write com.dylanfisher.searcher shortcuts -dict-add \
      window.showPalette '{ alternate = "cmd+shift+o"; }'
  ```

  `defaults delete com.dylanfisher.searcher shortcuts` resets them all.
- **The filter field's arrows.** ↑ and ↓ in the filter field are the field's own keys, as Tab
  is: they run Select Previous and Next Row by ID, whatever chords the user gave those commands
  or gave ↑ and ↓ to.

### SK.1b, menus and routing

- **A hidden item for the alternate.** Each command's item shows the first of its effective
  chords that can be a key equivalent, and a hidden item next to it, with the same action and
  `representedObject`, `isHidden` and `allowsKeyEquivalentWhenHidden`, has the second. The
  alternate so goes through the menu's key equivalents, the window controller's validation and
  `runMenuCommand:`, and works in text fields too, for the commands whose items work there
  ([0089](0089-sidebar-key-routing.md)). Every command item has its hidden item, with or without
  a chord, so the items can change in place.
- **Changes show at once.** `MainMenuBuilder.install` takes the `Settings` and makes the menus
  from `PaneViewController.registry(for:)`; after each change of the settings,
  `showChords(in:registry:)` sets every command item's key equivalent again from the cached
  registry. Context menus read the registry each time they are built, and the palette shows the
  first chord of the focused table's registry, so both follow too.
- **Edit items run their commands by ID.** `StandardAction.command` names the command each of
  Undo, Redo, Cut, Copy, Paste and Select All runs in the table, whatever chords the user gives
  it. The six items keep their own chords (Cmd-Z, Shift-Cmd-Z, Cmd-X, Cmd-C, Cmd-V, Cmd-A), so a
  text field always has them. The command's other chords go on a hidden item beside the Edit item
  that sends the same action, so in a text field an alternate of Copy copies the text. No other
  command's item shows one of the six chords: two items on one key leave the choice to AppKit.
- **Plain keys.** A chord with no Cmd, Ctrl or Opt that isn't an F-key never becomes a key
  equivalent (`KeyChord.canBeKeyEquivalent`); the rule moved from `.commandWithoutKey` to the
  chord ([0060](0060-menu-items-for-every-command.md)). It reaches the command from the table's
  `keyDown` only, and a plain letter takes that letter from type-select. The Selection submenu
  shows no chords at all, as before.
- **Settings….** The app menu has Settings… on Cmd-, after About. It sends `showSettings:`
  (`SettingsShowing`) up the responder chain; nothing answers it until SK.1c adds the window, so
  AppKit shows it off. Its chord is reserved now, so no stored shortcut can take it.

### SK.1c, the Settings window

- One Settings window (App menu ▸ Settings…, Cmd-,) with a Shortcuts pane: a search field, the
  commands grouped as the menus are, and per row the title, a recorder for each slot, Reset, and
  "is used by" with Replace and Cancel on a conflict. Reset All in the footer.
- The recorder takes the next key press through a local event monitor: Esc cancels, Delete
  removes the chord, a reserved chord is refused. The monitor is removed when recording ends.

## Alternatives considered

- **A list of any number of chords per command** — rejected: a settings row needs a fixed
  shape, and no default has more than two.
- **Refuse a chord another command has** — rejected: the user would have to find and unbind the
  other command first. Replace after asking keeps one meaning per key.
- **Throw or trap on stored data that clashes** — rejected: data the user wrote must never stop
  the app; the user's chord wins and the loss is logged.
- **Store each chord as `KeyChord.description` ("Cmd-Shift-K")** — rejected: the minus key would
  need escaping. "+" is only ambiguous as the last key, which `init?(stored:)` reads as the key.
- **Store every slot, defaults included** — rejected: a changed default would never reach a
  user who had not changed that command.

## Consequences

A default that later moves to a chord the user gave another command is lost to that command
until the user resets theirs.

The six Edit items take their chords first wherever the keys are. A command the user gives
Cmd-C (or another of the six) through stored data shows no key equivalent for it and never gets
it from the keyboard; `KeyBindings` doesn't know the Edit items, so SK.1c's recorder has to treat
the six chords as their commands' own and refuse them for any other.

A Shift-digit chord, such as Cmd-Opt-Shift-1, doesn't match the "!" a US keyboard types, so as a
hidden item's key equivalent it works only from the table's `keyDown`, as it did as a visible
one.

Reading drops an entry whose command ID the running build doesn't have and writes the rest back.
Two builds that share a defaults domain, such as an older and a newer one with a renamed
command, therefore remove each other's entries for commands only the other has.

`KeyChord(stored:)` checks the spelling, not the keyboard: it accepts `cmd+shift+>` as well as
`cmd+shift+.`, though recording only ever writes the key's own character. Which characters are a
key's own depends on the layout ("&" is the 1 key's own on AZERTY, and Shift-7 on US), and
Browser doesn't know the layout, so it can't reject the typed form. A hand-written
`cmd+shift+>` runs through the typed candidate on US, but the registry sees it as a chord apart
from `cmd+shift+.`, so a clash between the two goes unnoticed.
