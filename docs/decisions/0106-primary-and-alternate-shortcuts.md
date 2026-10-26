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
  (Quit, Hide, Hide Others, Minimize): the item always takes the key first.
  `MainMenuBuilder.reservedChords` derives them from the menus, and `KeyBindings` drops one that
  stored data names. SK.1b adds Cmd-, for Settings….
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

- The visible item shows the effective primary. The alternate gets a hidden item next to it,
  with the same action and `representedObject`, `isHidden` and `allowsKeyEquivalentWhenHidden`,
  so it goes through the menu's key equivalents and works in text fields too.
  `MainMenuBuilder.showChords(in:registry:)` updates the items when `Settings` changes.
- `StandardAction` gets `command: CommandID?`: the six Edit items run that command rather than
  looking up their chord. Their primaries are the Edit items' fixed chords; their alternates can
  be changed.
- A plain key (no Cmd, Ctrl or Opt, and not an F-key) is allowed and never becomes a menu key
  equivalent; the rule moves from `.commandWithoutKey` to the chord
  ([0060](0060-menu-items-for-every-command.md)). A plain letter takes that letter from
  type-select.

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
until the user resets theirs. Until SK.1b the menus are built once at launch and show only the
primary, so an alternate still works only through the pane's keys, as before.

Reading drops an entry whose command ID the running build doesn't have and writes the rest back.
Two builds that share a defaults domain, such as an older and a newer one with a renamed
command, therefore remove each other's entries for commands only the other has.

`KeyChord(stored:)` checks the spelling, not the keyboard: it accepts `cmd+shift+>` as well as
`cmd+shift+.`, though recording only ever writes the key's own character. Which characters are a
key's own depends on the layout ("&" is the 1 key's own on AZERTY, and Shift-7 on US), and
Browser doesn't know the layout, so it can't reject the typed form. A hand-written
`cmd+shift+>` runs through the typed candidate on US, but the registry sees it as a chord apart
from `cmd+shift+.`, so a clash between the two goes unnoticed.
