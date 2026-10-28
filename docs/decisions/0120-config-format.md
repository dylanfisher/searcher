# 0120. Config file: format, keys, precedence over the app's values, and errors

- **Date:** 2026-10-27
- **Status:** accepted

## Context

M5b.1 adds a plain-text config file at `~/.config/searcher/config`. Until now `Settings` read
every preference from `UserDefaults` only ([0031](0031-view-settings.md),
[0100](0100-appearance-and-ds-store.md), [0107](0107-sidebar-favorites.md)), and the app's
toggles write there. The plan asks for the file to be parsed off the main actor, read again when
it changes, never written over by the app, and reported by line when it is wrong. M5b.2 follows
and adds shortcut lines to the same file and parser.

## Decision

- **Format.** One setting a line, `key = value`. Keys are lowercase words joined by dashes
  (`folders-first`). A value is `true` or `false`, a number, or a string, bare or in double
  quotes; in quotes `\"` is a quote, `\\` a backslash, and `#` is text. A `#` outside quotes
  starts a comment to the end of the line; blank lines are ignored. Windows line endings count
  as one line break. `ConfigParser` reads it.
- **Errors.** Each says its line, the key when the line has one, and why, in plain words:
  `line 3: unknown key "show-hiden"`, `line 4: folders-first must be true or false, not "yes"`,
  `line 5: no "=" between a key and its value`, a key set twice, a missing value, an unclosed
  quote, text after a closing quote, a number outside its range, a name not among the choices,
  an empty string. A file that isn't UTF-8 or can't be read is an error with no line. A file
  with any error sets nothing: the values from the last good read stay, which are the defaults
  at launch. Every error is logged once, when the file's read changes, under the `config`
  category.
- **Keys.** Only preferences a user sets: `show-hidden`, `hide-ds-store`, `folders-first`,
  `folder-sizes`, `columns-start-at-home`, `column-width`, `appearance`, `terminal-bundle-id`,
  `commander-f-keys`, `hide-empty-operations-panel`, `sidebar-favorites`, `sidebar-locations`
  and `sidebar-workspaces`. `column-width` is the width a new column starts at, which a user may
  want set by hand; an Option-drag in the app still sets it there. State the app keeps by
  itself is left out: the favorites, the new window frame, the palette's place and per-window
  column widths are where the user left things, not choices typed ahead of time. Shortcuts wait
  for M5b.2.
- **One declaration per key.** `Settings.preferences` lists each preference once: its
  `UserDefaults` key, its name in the file, the kind of value it takes, its default and a
  one-line summary. The parser's known keys, its checks, the stored-value checks in `Settings`
  and `ConfigTemplate` all come from it, and the default is nowhere else.
- **Precedence.** A preference reads as the value the app stored, then the file's, then its
  default. A change made in the app is stored in `UserDefaults` as before and wins over the
  file. A change in the app to the value the file has removes the app's value instead of
  storing it, so the preference follows the file again; stored, it would become an override
  the next edit of the file couldn't change. The app never writes the file.
- **Overrides are shown and can be undone.** A key the app set to a value other than the file's
  would keep overriding the file with no sign of it, so Settings ▸ General lists each one under
  the config file's section: the key, "Searcher has false; the config file has true.", and a
  Use Config File Value button, which removes the app's value so the file's applies. An app
  value equal to the file's isn't listed: it changes nothing until the file changes, and then
  it is. The list follows `Settings.configOverrides` as either side changes: a read of the
  file tells the observers when the overrides change, even when every value reads as before,
  as when the file comes to agree with the app or is deleted.
- **Reading.** `ConfigWatcher`, an actor, reads the file and watches its folder with
  `FileEventStream`. It watches the folder, not the file, because an editor's atomic save
  replaces the file, and a deletion is a change like any other: no file reads as every default.
  The folder may not exist yet; FSEvents matches each change by its path, so changes made once
  the folder is created arrive on the same stream. The watch starts after the first read, and
  the file is read once more as it starts, so a change between the two isn't missed. Each read
  that differs from the last goes to `loads`, in order. At launch `Settings.follow(_:)` applies
  the first read before the windows are restored, so they open with the file's values, and
  applies each later one as it comes.
- **Banner.** The errors show in a strip across the top of every browser window, over the tab
  strip, rather than in an alert as store problems do: the file is edited while the app runs,
  and an alert on every save of a half-edited line would get in the way. It names the first
  error and how many more there are, lists them all in its tooltip, and has an Open Config File
  button. It hides when a good file, or none, is read.
- **Open Config File.** A registered command (`system.openConfigFile`) with no default chord, in
  the app menu under Settings…, and a button in the General pane and in the banner. Off the
  main thread it makes the folder and the file from `ConfigTemplate`, only when there is no
  file, then opens the file in the default app for plain text through `SystemActions`. The write
  is `AtomicWrite.create`, whose rename is `renamex_np` with `RENAME_EXCL`, so a file an editor
  saves between the check and the write is kept and opened. A file that can't be made shows in
  the banner; that includes a volume whose rename can't take `RENAME_EXCL` (`ENOTSUP`), which
  fails loudly rather than fall back to a rename that could replace a file. A symbolic link at
  the path to a file that isn't there is reported in the banner and not opened or written
  through; the watcher reads such a link as no file. A folder at the path is reported the same
  way. Such an error goes through the watcher as if a read had found it, so the next read of
  the file clears it, even one that reads as no file again. With no browser window open, or the
  Settings window in front, the item reaches the app delegate, which hands it to
  `AppMenuResponder` in Interface, as it does New Window.
- **Template.** A header on how the file reads and that the app's values win, then each
  preference's summary and its line commented out at its default, so a new file sets nothing.
- **Adding a key family (M5b.2).** The parser reads in two steps: each line into a key and a
  value as written (`ConfigParser.Entry`), then each entry against what its key names. A family
  such as repeated `bind` lines, or dotted keys such as `shortcut.window.showPalette`, is
  matched in the second step before the preference lookup, by its key or prefix, and may take
  the key more than once; the duplicate-key check is the preferences' own. Its values join
  `ConfigLoad` beside the preference values, and the template appends its section.

## Alternatives considered

- **TOML or JSON** — rejected: a flat list of settings needs no tables or nesting, and a parser
  for either is a new dependency or a large one to write. The format here is a TOML subset for
  what it has.
- **Write the app's toggles into the file** — rejected: the plan forbids writing over the
  user's file, and rewriting it would lose their comments and order.
- **The file wins over the app** — rejected: a toggle in the View menu that reverted on the next
  read of the file would look broken.
- **Apply the good lines of a file with errors** — rejected: half a file applied makes the
  result depend on which line was mistyped, and a key set twice would have no clear winner.
- **An alert for errors, as `StoreProblem`s get** — rejected: see Banner.
- **A Clear Overrides command** — rejected: a per-key button in the pane says which keys differ
  and what each side holds before anything changes.

## Consequences

Launch reads the config file, a few hundred bytes, before the windows are restored, on the
watcher's actor, beside the store's read. The FSEvents stream costs no file descriptor. A save
by an editor that writes in place can be read half written, which shows an error until the
write's own event brings the whole file. Every preference is now a computed property over the
app's and the file's values, so `UserDefaults` holds only what the app changed, as before.

## Amendment: shortcuts (2026-10-27)

M5b.2 added shortcut lines ([0122](0122-config-shortcuts.md)): `shortcut.<command ID>.<slot> =
<chord>` or `= none`, matched by the `shortcut.` prefix in the second step, as Adding a key
family planned. Their keys keep the command IDs' own spelling, dots and capitals, rather than
this record's lowercase dashes. `ConfigLoad` carries them beside the preference values, each
with its line, and `ConfigWatcher` now takes the menus' reserved and fixed chords, so a read
can turn a shortcut those chords refuse into an error on its line before anything applies. The
template appends every command's slots. The Shortcuts pane lists the app's shortcut overrides
of the file under each row, with Use Config File Value; the General pane's list stays the
preferences'.
