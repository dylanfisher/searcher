# 0031. View settings: hidden files and folders first are app-wide, in UserDefaults

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M1.4 adds Cmd-Shift-. to show and hide hidden files, a View menu item for folders first, and
the sort keys Ctrl-Opt-Cmd-1, 2, 5 and 6 (`tmp/behavior.md`). The two toggles need a home that
survives a relaunch, and every pane has to follow a change. M5b.1 adds a config file that sets
the same preferences. Hidden needs a definition: macOS hides a file two ways, a name that starts
with a dot and the `UF_HIDDEN` flag ([0028](0028-folded-names.md) keeps the flag on each entry).
B8 (150 ms on W2) covers each change, and B10 and the rule against per-entry work on the main
thread apply as they do to a sort change ([0025](0025-sort-off-main.md),
[0029](0029-row-movement.md)).

## Decision

- **App-wide, in `UserDefaults`.** `Settings` holds `showHidden` and `foldersFirst`, both off
  by default as in Finder, and is the only type that reads or writes them. The app passes
  `UserDefaults.standard`; tests and the UI bench pass a suite of their own, named by a path
  in a temporary folder, so they never read or write the user's preferences. Each pane holds
  the one `Settings` and observes it, so a change reaches every pane at once, and the
  View menu's check marks follow it the same way. From M5b.1 the config file sets these values,
  and a toggle made in the app is kept in `UserDefaults` and overrides the file's value.
- **Stored data has one shape.** A missing key reads as the default. A value that isn't a
  Boolean is removed and reads as the default too: `UserDefaults.bool(forKey:)` would read the
  string "YES" or the number 1 as true.
- **What counts as hidden.** An entry is hidden when its name starts with a dot or it has the
  `UF_HIDDEN` flag (`Listing.isHidden`). Nothing else: not `.hidden` files, the `/` entries
  Finder hides by a list, or the extension-hiding flag.
- **Folders first.** An entry of kind Folder, a directory that isn't a package, sorts before
  everything else in each column and direction; within each group the column's order holds. An
  app or other package sorts with the files, as in Finder. A symbolic link to a folder is a
  file, since following it takes a call per link.
- **One sort path.** `Listing` keeps hidden entries and gives them no row, and both toggles
  are options of `Listing.sort`, next to the column and direction. A toggle makes the pane's
  `startSortIfNeeded` sort a copy on its sort queue, as a column change does, and loads are
  asked for the settings, so a folder opened with hidden files off never shows them. Patches
  keep hidden entries out of the rows.
- **Selection.** The selection follows its entries by name. Showing or hiding hidden entries
  changes which entries the rows hold, so the worker resolves the selection as it does after a
  load: hidden files that appear aren't taken into a Select All, which never saw them, and
  selected entries that are hidden leave the selection. When the cursor's entry is hidden, the
  cursor moves to the row that followed it, or the last row when none did, and that row is
  selected if nothing else is. Folders first keeps the entries, so the selection only moves.
- **Sort keys.** Ctrl-Opt-Cmd-1, 2, 5 and 6 sort the focused pane by Name, Kind, Date
  Modified and Size. A column starts in the direction a header click does (`SortColumn`
  `firstAscending`: Size and Date Modified largest and newest first), and the key of the column
  already sorted by reverses it.
- **Cmd-Shift-.** AppKit applies Shift to punctuation, and where "." sits depends on the
  layout. On a US keyboard the period key with Shift types ">"; on a French AZERTY one, "." is
  Shift on the ";" key. A shifted punctuation key therefore has two candidate chords
  (`KeyChord.candidates(for:)`): the character typed, then the key's own character read
  without Shift from the key code and layout. The table runs the first one registered, so
  Cmd-Shift-. finds `.` with Command and Shift on both layouts, through the key's own character
  on US and the typed one on AZERTY. A layout where "." can't be typed with Shift alone doesn't
  reach it. A menu item with "." and Command-Shift as its key equivalent didn't match a ">"
  event in a test of `NSMenu.performKeyEquivalent`, so the key may reach the command through
  the table's `keyDown` rather than the menu; both run the same command.
- **Bench.** The harness times each command on a freshly listed pane with one row selected,
  to the pane holding the rearranged rows with the selection settled: showing and hiding hidden
  files and folders first on W2 (B8) and W5 (reported), and the sort key for Size on W2 (B8).
  The UI bench presses Cmd-Shift-. twice, runs Folders First twice and presses two sort keys
  on W2 after the sort change, each timed to its frame as its own B8 case.

## Alternatives considered

- **Per-pane or per-folder settings** — rejected: the plan makes both app-wide, and a per-folder
  store needs its own lifetime and cleanup.
- **Filter hidden entries in the lister, or list again on a toggle** — rejected: showing them
  again would read the folder, which on a share is slow (B10), where a sort of the entries
  already listed takes milliseconds.
- **A second listing for the filtered rows** — rejected: patches, the selection and the sort
  would each have to keep two in step.
- **Read `UserDefaults.bool(forKey:)`** — rejected: it coerces strings and numbers.
- **Observe `UserDefaults` change notifications** — rejected: they arrive for every key in the
  suite and from other processes, on the posting thread; the setter already knows the change.

## Consequences

The plain `UserDefaults` domain holds two Boolean keys, `showHidden` and `foldersFirst`.
Listings keep hidden entries in memory while they are hidden: W2's 1% dot files cost about
1% of its listing. A toggle while a large folder is still loading drops hidden selected names
only once the full listing arrives. Whether AppKit's menu takes Cmd-Shift-. with a real key
press is unchecked; the command runs either way. The table doesn't scroll to the cursor after
a toggle, as it doesn't after a folder change patch.
