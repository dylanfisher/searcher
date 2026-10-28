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
- **Each change in the app is a patch, written by read-modify-write.** A change in the app sets
  the setting in memory at once and hands the `ConfigStore` actor a `ConfigPatch`: one
  preference and its value, or one shortcut slot and its chord, `""` for none, or its default.
  The store takes patches in the order they were made and writes each by reading the file,
  setting that one key in the file's JSON object, leaving every other key as the file has it,
  and writing the object back through `AtomicWrite`, pretty-printed with sorted keys. Just before
  the rename the file's bytes are compared with that read, through `AtomicWrite`'s
  `beforeRename`, and on a difference the patch starts over from a new read. What is left is
  the few microseconds between that check and the rename, which no rename can close:
  `rename(2)` can't be made conditional on the bytes it replaces. Because each patch reads the
  file first, an editor's change to another key is never overwritten, and an editor's change to
  the same key is overwritten only by a later change in the app, the newer action. There is no
  write delay: a toggle costs one small read and one write, off the main thread. Patches still
  waiting are coalesced only by key, the latest winning. A patch whose value the file already
  has writes nothing, so the user's spelling of the file stays.
- **A new file holds every option.** When there is no file, at launch, at a newly chosen place,
  or once a deletion is confirmed with patches waiting, the file is made with every preference
  at its value and `"shortcuts"` with the commands the user changed (`{}` for none), so the user
  can see each option.
- **Reads.** A save in an editor, or any change in the file's folder, makes the store read the
  file and send what it finds to `Settings`, which applies it at once, every key. The patches
  not yet written go on top, in the store's read and again in `Settings`, which keeps those it
  sent until the store says they are in the file, so a read sent before the store took a patch
  doesn't undo it. `ConfigStore` watches the file's folder with FSEvents as 0120's watcher did.
  The store keeps the file's bytes as last read or written, and a read that finds the same
  settings sends nothing, so the app's own write never comes back as a reload; files beside the
  config file, such as Dropbox's conflicted copies and `AtomicWrite`'s partial file, change
  nothing.
- **Reads that pass through.** An editor's save in place truncates the file and then writes it,
  and a sync tool may delete it and create it again. A read that finds the file empty or gone,
  where the last read didn't, isn't sent: the store reads again `ConfigStore.confirmDelay`
  (200 ms) later, on its injected clock, and takes what that read finds; a change in the folder
  before then cancels the wait and reads at once. 200 ms covers a save in place and a delete
  and create, which take milliseconds, and is short enough that a real deletion shows at once to
  a person. Patches meanwhile wait.
- **A deleted file means the defaults.** The file is the settings, so a deletion while the app
  runs, once confirmed, sets every preference and shortcut to its default, with the patches
  waiting on top; those are written as a new file. With none waiting nothing is written then;
  the next change in the app, Open Config File, or the next launch writes a fresh file.
- **Errors: simple, and the file isn't applied.** Text that isn't JSON is one error on the line
  Foundation stopped at (its error gives the byte offset; the line is counted from it), with
  Foundation's description: `line 3: isn't valid JSON: Something looked like a 'true' but
  wasn't`. A known key with a wrong type or value names the key and what it takes:
  `folders-first must be true or false, not "yes"`. **An unknown key is an error**, not ignored:
  a typo such as `show-hiden` would otherwise do nothing silently, and the cost, a key from a
  newer build being refused, doesn't arise before release. Shortcut errors name their key
  (`shortcuts.window.showPalette.alternate`); the menus' reserved and fixed chords are still
  checked by the store (0122's `ConfigLoad.checked(reserved:fixed:)`). A key an object has twice,
  which Foundation's parser would take the last of without a word, is an error on the line of
  the second, found by a short scan of the text after it parses. Two slots given one chord
  is no error: `KeyBindings` gives it to the first command and logs the other, as for any
  override, because the Shortcuts pane could otherwise write a file the app then refused. Errors
  show in `ConfigErrorBanner` and are logged under `config`. A file with an error sets nothing;
  the last good settings stay.
- **A broken file is never written over.** While the file has an error, or is found empty or
  gone and not yet confirmed so, the patches wait in the store's queue, in order, and memory
  already shows them; the banner says the changes can't be saved to the file until it is fixed.
  When a good read arrives, the store writes the queued patches on top of it, in order. The
  later action wins: a change in the app made while the file was broken was made after the
  user's last save, and the user's fix keeps every key the queue doesn't touch.
- **A write that fails** (no permission, a share that's down) keeps its patches at the head of
  the queue and shows in the banner until a write succeeds. The store tries again on its clock
  after `ConfigStore.firstRetryDelay` (1 s), doubling each time up to
  `ConfigStore.longestRetryDelay` (30 s), so a failing write never loops fast. A write whose
  file changes under it on each of `ConfigStore.attempts` tries waits for its retry the same
  way, and shows so in the banner. While a patch waits for its retry, or for the second read of
  a file found empty or gone, an edit of the file that changes the patch's key from one good
  read to the next drops the patch, in the store and in `Settings`: the edit came later, and
  the later action wins. A patch held by a file with an error is kept instead, since the user
  may be fixing something else, and goes on top of the fix as above.
- **Quitting.** `Settings.flushConfig(by:clock:)` waits for the store's queue to drain, a
  confirm read and its replay among it, up to the quit deadline, beside the other quit steps
  rather than before them (`FirstToFinish`, as the listing cache's flush runs): a config file on
  a share that hangs delays no step. At the deadline the app logs the keys that didn't reach the
  file (`Settings.unwrittenConfigKeys`) and quits.
- **Location.** The default is `~/.config/searcher/config.json`. Settings ▸ General shows the
  path, with Change… (an `NSOpenPanel` that takes a JSON file or a folder, in which the file is
  `config.json`), Open in Editor (Open Config File), Reveal in Finder and Use Default. The chosen
  location is the one thing kept outside the file, as a path in `UserDefaults` under
  `configFile`; a value that isn't an absolute path is discarded and logged. A plain path is
  enough: the app isn't sandboxed (`scripts/bundle` signs it with no entitlements), so no
  security-scoped bookmark is needed, and a path, unlike a bookmark, stays at the place the
  user chose when the file there is replaced by a sync. Reveal in Finder checks off the main
  thread that the file is there, and when it isn't, as on a volume that isn't connected, says
  so under the buttons and to VoiceOver instead of showing Finder nothing.
- **Moving.** Change… waits up to `Settings.moveWait` (2 s) for the old place's queue to drain,
  so an old place on a share that hangs can't hold the move, then hands the patches not yet
  written to the new place's store, which takes them after its first read. Choosing a place with
  a config file reads it ("pull") and writes the handed-over patches on top; choosing one with
  none writes the settings there ("save"), those patches among them. A change made while the
  new store reads the file goes the same way, so the read doesn't undo it.
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
- **The whole file written after a delay, with reads merged against a snapshot** — what this
  record first decided, rejected after two reviews: the bookkeeping that kept app and file in
  step (keys changed since the last write, a snapshot of the file, generations of reads, a
  delayed write) lost a change in two more interleavings, a quit after a refused write and an
  editor's save during a write. A patch read-modify-written per change needs none of it.
- **Apply an empty or missing read at once** — rejected in review: a save in place flashed the
  banner and a sync tool's delete and create reset the settings to their defaults.
- **A security-scoped bookmark for the chosen location** — rejected: not sandboxed, and see above.
- **NSSavePanel for a new file name** — rejected: one open panel that takes a folder covers the
  Dropbox case, and a file picked in it covers the rest.

## Consequences

Launch reads one small file before the windows restore, on the store's actor, and writes it
when it is missing. Each change in the app costs one read and one write of a few hundred bytes
at once, on the store's actor. The user loses, on the first launch with this build, every
preference and shortcut they had set in the app or in the line-format file: both start at their
defaults until set again.
