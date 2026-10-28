# 0123. The config file is the settings: one JSON file the app reads and writes

- **Date:** 2026-10-27
- **Status:** accepted
- **Supersedes:** [0120](0120-config-format.md) and [0122](0122-config-shortcuts.md)
- **Amends:** [0031](0031-view-settings.md), [0100](0100-appearance-and-ds-store.md),
  [0106](0106-primary-and-alternate-shortcuts.md), [0107](0107-sidebar-favorites.md),
  [0110](0110-interaction-states.md)

## Context

Dylan, 2026-10-27: "config file should be json / you should be able to set a config file
location and it will save/pull from the config at that location. e.g. i want my config on my
dropbox so it's always backed up / config file should update settings immediately when it's
saved. i set appearance = dark and don't see it changing / the config file isn't something that
overrides the settings you have in the GUI app, it's the same state as the settings. like in
sublime text. / config should have a parser and check for errors and tell you if you have an
error and ideally what it is (but don't make this a big complex feature, just something simple
and effective)".

**Why "appearance = dark" didn't apply.** The file was read and applied, but 0120 let a value the
app had stored in `UserDefaults` win over the file's. His preferences held `appearance = auto`
from the app (`defaults read com.dylanfisher.Searcher appearance` printed `auto`), so the
preference read as auto whatever the file said. The General pane listed it as an override, which
nothing pointed him to. The cause is the override layer itself, so this record removes it rather
than adding a warning.

## Decision

- **One JSON file holds the preferences and the shortcuts.** Every key of
  `Settings.preferences`, under the same names 0120 gave them (`show-hidden`, `appearance`, …),
  and the user's shortcuts under one `"shortcuts"` object in 0106's stored shape: command ID →
  `{"primary": "cmd+k", "alternate": ""}`, where `""` takes the slot's chord away and a slot
  left out keeps its default. `ConfigFile` parses and writes it. The app reads it and writes it;
  there is no second copy and no override layer, so no "Use Config File Value".
- **App state stays where it was.** Favorites, the new window frame, the palette's place, column
  widths per window and the workspaces stay in `UserDefaults` or the workspace store: they are
  where the user left things, not choices.
- **One declaration per key.** `Settings.preferences` gives each preference its key, kind and
  default; the file's keys, its checks and what the app writes come from it. The template's
  one-line summaries went with the template: JSON has no comments.
- **Writing.** A change in the app writes the whole file: pretty-printed, keys sorted, every
  preference present at its value, so the file shows every option, and `"shortcuts"` with only
  the commands the user changed (`{}` for none). The write goes through `AtomicWrite` on the
  `ConfigStore` actor, `WorkspaceStore.writeDelay` after the first change not yet written, as
  the workspace store times its writes; quitting writes a waiting change at once. A file the app
  hasn't changed is never rewritten, so the user's own formatting stays until the next change in
  the app.
- **No echo, and the file wins a race.** The store keeps the file's bytes as last read or
  written; a change event whose read gives the same bytes, or the same settings, sends nothing,
  so the app's own write never comes back as a reload. Each read the store sends has the next
  generation, and each write says which generation the settings had applied; a write based on an
  older one is dropped, and so is one that arrives after a later write. Before writing, the store
  reads the file once more, and an edit whose event hasn't arrived yet is sent and wins. So an
  edit saved in an editor is never overwritten by a change in the app that hadn't seen it.
- **Reading.** A save applies at once, every key; `ConfigStore` watches the file's folder with
  FSEvents as 0120's watcher did, since an editor's save and Dropbox's replace the file by
  rename. Files beside it, such as Dropbox's conflicted copies and `AtomicWrite`'s partial file,
  change nothing: the bytes of the config file are the same.
- **A deleted file means the defaults.** The file is the settings, so a deletion while the app
  runs sets every preference and shortcut to its default. Nothing is written then; the next
  change in the app, Open Config File, or the next launch writes a fresh file. A file missing at
  launch, or at a newly chosen place, is written from the settings at once.
- **Errors: simple, and the file isn't applied.** Text that isn't JSON is one error on the line
  Foundation stopped at (its error gives the byte offset; the line is counted from it), with
  Foundation's description: `line 3: isn't valid JSON: Something looked like a 'true' but
  wasn't`. A known key with a wrong type or value names the key and what it takes:
  `folders-first must be true or false, not "yes"`. **An unknown key is an error**, not ignored:
  a typo such as `show-hiden` would otherwise do nothing silently, and the cost, a key from a
  newer build being refused, doesn't arise before release. Shortcut errors name their key
  (`shortcuts.window.showPalette.alternate`); the menus' reserved and fixed chords are still
  checked by the store (0122's `ConfigLoad.checked(reserved:fixed:)`). Two slots given one chord
  is no error: `KeyBindings` gives it to the first command and logs the other, as for any
  override, because the Shortcuts pane could otherwise write a file the app then refused. Errors
  show in `ConfigErrorBanner` and are logged under `config`. A file with an error sets nothing;
  the last good settings stay.
- **A broken file is never written over.** While the file has an error, changes in the app apply
  in memory and the banner says they can't be saved to the file until it is fixed. When a good
  file loads, the file wins and those changes are dropped: the file is the settings, and the
  user was editing it. A write that fails (disk full, no permission) shows in the banner too,
  until a write succeeds; the change stays in memory and the next change tries again.
- **Location.** The default is `~/.config/searcher/config.json`. Settings ▸ General shows the
  path, with Change… (an `NSOpenPanel` that takes a JSON file or a folder, in which the file is
  `config.json`), Open in Editor (Open Config File), Reveal in Finder and Use Default. The chosen
  location is the one thing kept outside the file, as a path in `UserDefaults` under
  `configFile`; a value that isn't an absolute path is discarded and logged. A plain path is
  enough: the app isn't sandboxed (`scripts/bundle` signs it with no entitlements), so no
  security-scoped bookmark is needed, and a path, unlike a bookmark, stays at the place the user
  chose when the file there is replaced by a sync. Choosing a place with a config file reads it
  ("pull"); choosing one with none writes the settings there ("save"). A waiting change is
  written to the old file first.
- **A missing volume is an error, never a fallback.** The store makes the file's folder only at
  the default location. At a chosen one, a missing folder is an error ("is in …, which isn't
  there: is its volume connected?"), shown in the banner, with the settings kept in memory and
  nothing written; the default location is not used in its place, now or at the next launch.
  When the volume comes back, FSEvents reports the file by its path and it is read.
- **Symbolic links.** A link at the config file's path, as dotfiles kept in another folder are,
  is read through and written through: the write goes to the file the link leads to (through up
  to eight links), so the link stays a link. Both the link's folder and the target's are
  watched; a link retargeted while the app runs is followed at the next launch or move. A link to
  nothing is an error and isn't written through. A chosen folder that is itself a link, as
  `~/Dropbox` may be, needs nothing: only the file's own name matters to the rename.
- **Existing data isn't read** (AGENTS.md, pre-release). The line-format file at
  `~/.config/searcher/config` and the preferences and `shortcuts` key in `UserDefaults` are left
  where they are and not read.
- **Interaction states** ([0110](0110-interaction-states.md)). Change…, Open in Editor, Reveal in
  Finder and Use Default are SwiftUI bordered buttons, which AppKit draws hovered, pressed,
  focused and disabled; Use Default is disabled at the default location.

## Alternatives considered

- **Keep the override layer and warn about it** — rejected: Dylan's model is that the file is
  the settings, and a warning still leaves two values for one setting.
- **Ignore unknown keys and list them** — rejected: a second kind of message for a case an error
  already covers, and a typo would still apply nothing until the list is noticed.
- **A deleted file rewrites the current settings at once** — rejected: a sync tool that replaces
  the file by delete and create could have its new file raced by the app's write, and the user's
  model is that deleting the file resets it.
- **Keep the app's unsaved changes when a good file loads** — rejected: merging needs a rule per
  key, and the user's edit is the newer intent.
- **A security-scoped bookmark for the chosen location** — rejected: not sandboxed, and see above.
- **NSSavePanel for a new file name** — rejected: one open panel that takes a folder covers the
  Dropbox case, and a file picked in it covers the rest.

## Consequences

Launch reads one small file before the windows restore, on the store's actor, and writes it
when it is missing. Each change in the app costs one write of a few hundred bytes a second
later. The user loses, on the first launch with this build, every preference and shortcut they
had set in the app or in the line-format file: both start at their defaults until set again.
