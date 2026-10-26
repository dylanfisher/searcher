# 0010. Commands are data; a chord has one spelling

- **Date:** 2026-10-20
- **Status:** accepted

## Context

Every key is a registered command, looked up by chord when a key is pressed and by ID when a menu
is built. Two keys must never mean the same thing, and the clash has to show up in a test rather
than at the keyboard. What a command acts on (the focused pane, the workspace) doesn't exist yet,
and the key event that becomes a chord is an AppKit type that Browser can't import.

## Decision

`Command` holds an ID, a title and its default chords, and nothing else. `CommandRegistry` is a
value type whose `register` throws a `Conflict` naming both commands when an ID or any chord is
taken, and adds nothing in that case. A command that lists one chord twice stops at a
precondition. Each chord has exactly one spelling: `KeyChord.init`, the only way to build a chord,
traps on an uppercase character (Cmd-Shift-G is `"g"` with `[.command, .shift]`) and on a
whitespace or control character (`" "`, `"\t"`, `"\r"`, escape, delete), which are written as the
named keys `.space`, `.tab`, `.return`, `.escape` and `.delete`.

## Alternatives considered

- **An action closure on `Command`** — rejected for now: its parameter would be a context type
  that isn't designed yet. The action can live in the command set instead, such as
  `NavigationCommands` pairing each `Command` with a handler, which leaves this record's files
  unchanged. The step that adds the first real commands decides.
- **Check spellings only in the character literal initializer** — rejected: `.character("G")`
  and `.character(" ")` would bypass it, and a binding written either way would never match the
  chord a key event produces.
- **Store the shifted character (`"G"`, `">"`)** — rejected: `"G"` with Cmd and `"G"` with
  Cmd-Shift would both mean Cmd-Shift-G, and the registry couldn't see them collide.
- **Last registration wins** — rejected: a clash would be silent, and which binding won would
  depend on registration order.

## Consequences

Interface's `NSEvent` conversion must produce the unshifted character:
`charactersIgnoringModifiers` still applies Shift, so Shift-G arrives as `"G"`, and it must map
space, tab, return, escape and delete to their named keys rather than pass them through as
characters, or `KeyChord.init` traps. `KeyChord(event:)` lowercases letters, which covers Shift
and Caps Lock, but a shifted punctuation key still arrives shifted (Shift-. as `">"`); the step
that binds one reads `characters(byApplyingModifiers:)` instead. Keys other than
characters, arrows, Tab, Return, Delete, Space and Esc (Page Up/Down, F-keys, Fn) are added to
`KeyChord.Key` when a step binds them.

## Amendment: two chords and user overrides (2026-10-26)

A command has two default chords at most, its primary and its alternate, which `Command.init`
checks. The registry the keys and menus use is built by `KeyBindings` from the defaults, the
Commander preset and the user's overrides ([0106](0106-primary-and-alternate-shortcuts.md)). A
clash between two defaults still throws; a clash that stored data makes is settled in favor of
the user's chord and never throws.
