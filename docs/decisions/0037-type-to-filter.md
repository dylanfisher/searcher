# 0037. Type-to-filter: a folded substring match on the arrange path, cleared by navigation

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M1.8 adds the filter field (`tmp/behavior.md`): Cmd-F opens it, typing narrows the pane to names
containing the text, Esc clears it and puts the focus back on the list, and navigating clears it
without Back bringing it back. Each key is held to B7, 50 ms on W2's 100k entries, and the main
thread may do no work per entry ([0025](0025-sort-off-main.md), B10). Names are folded once per
listing for matching ([0028](0028-folded-names.md)), and the pane already rearranges its rows off
the main thread for the sort, hidden files and folders first ([0031](0031-view-settings.md)). A
query can be typed faster than its rows are filtered, so an older result can land after a newer
one started.

## Decision

- **Match.** `NameFilter` folds the typed text with `NameSortKey.fold` and keeps an entry whose
  folded name contains it, comparing UTF-8 bytes with `memmem`, as 0028 asks. "port" keeps
  "Report.pdf" and "PORTFOLIO" and drops "readme"; "ré" keeps "Resume"; "가" keeps "각". Two
  filters that fold to the same text are equal, so "Port" after "port" filters nothing again. An
  empty filter keeps everything.
- **One more arrange option.** The filter is an option of `Listing.sort`, beside the column,
  hidden files and folders first, and `Listing` gives an entry the filter drops no row, as it
  does a hidden one: the entry stays in the listing, so widening the query is a sort, not a new
  listing. `Pane.setFilter` takes the text at once and calls `startSortIfNeeded`, which filters a
  copy on the sort queue; `isArranged` compares the filter too. Loads are asked for the pane's
  filter, so a reload while filtering arrives filtered. Patches go through `isShown`, so a file
  created while filtering gets a row only if it matches.
- **Latest query wins.** A result lands only if the state and the arrangement, filter included,
  are still the ones it started from (`finishSort`), so an older query's result arriving after a
  newer one started is dropped. The older work isn't stopped: on 100k entries it is one pass of
  matches, and 0025 already chose a dropped sort over a queue of requests.
- **Selection.** Changing the filter changes which entries the rows hold, so the worker resolves
  the selection as against a load, as showing hidden files does: selected entries the filter
  drops leave the selection once the folder is fully listed, and entries that come back aren't
  taken into a Select All. When the cursor's entry has no row, the cursor moves to the first row,
  which is selected if nothing else is (`Pane.keepingFirstRow`), so the selection stays if it
  matches and is the first row otherwise. A new filter scrolls the list to the cursor a pass
  later, as a new sort does.
- **Navigation clears it.** `Pane.leave`, which every move to another folder goes through (open,
  parent, path bar, Go to folder, a link to a folder, Back and Forward), clears the filter, and
  `History` keeps none, so Back shows the folder unfiltered. Opening a link to a file, or a go
  that finds no folder, leaves the pane where it is, filter included. Going to the folder the pane
  is in is a reload, not a navigation ([0033](0033-history-and-go-to-folder.md)), and keeps the
  filter.
- **The field.** `FilterBarView` is an `NSSearchField` above the list, hidden until Cmd-F
  (`ViewCommands.filter`, through `CommandContext.showFilter`). Taking focus selects its text.
  While it has focus, keys go to its field editor, so Cmd-A selects the text and Space types a
  space; ↑ and ↓ run the commands registered on them through the table's `run(_:)`, which moves
  the list's selection and ends a type-select query, and the field keeps focus. Esc clears the
  filter, hides the field and focuses the list. With the list focused, letters and Space still
  go to type-select and Quick Look ([0034](0034-type-to-select.md)). Filter's key pressed again in
  the field selects the field's text, as Find does in Finder and Safari: the menu item can't,
  since the list that runs commands isn't in the field's responder chain, so `FilterBarView`
  takes the key before the menu does. A fully listed folder with no matching names says "No items
  match “text”." over the list, with the text as typed: "Port" after "port" filters nothing again
  but changes the message.
- **Bench.** The harness times, on W2, each of the five keys that type the first five characters
  of the middle row's name, from `setFilter` to the pane holding the filtered rows with the
  selection settled, the shorter query typed untimed first (B7). The UI bench presses Cmd-F after
  the view settings, types the same five characters and Esc, and times each key to the frame that
  shows the rows filtered by the field's new text, as one B7 case.

## Alternatives considered

- **A separate filter pipeline over the arranged rows** — rejected: the sort, patches, the
  selection and the version checks would each need a second copy kept in step, which 0031
  rejected for hidden files on the same grounds.
- **Filter the rows the pane shows, without sorting again** — rejected: a shorter query needs
  rows the narrower one dropped, so it would need the unfiltered order kept beside the rows, a
  second array per listing patched with them. Sorting by name reuses the name order the listing
  keeps; another column sorts in 6 ms on W2 (0025).
- **Stop the older query's work when a newer one starts** — rejected for now: dropping its result
  is enough for correctness, and the pass it wastes is one match per entry off the main thread.
- **Match with `contains` or `range(of:)`** — rejected: they compare characters, and a decomposed
  Hangul syllable is one character (0028).
- **Keep the selection's cursor on the next matching row, as hiding does** — rejected: the plan
  asks for the first row when the selection doesn't match.
- **Keep the filter in History** — rejected: the key table says Back doesn't restore it.

## Consequences

The listing keeps every entry while filtered, as it does hidden ones, so memory doesn't drop with
the rows. Every lookup by name (`Listing.row(named:)`) runs one match more while a filter is set.
The harness and UI bench numbers are not measured yet. Filter sits in the File menu, where Finder
puts Find; it shows disabled while the field has focus, though its key still selects the
field's text. A synthetic key event typing into the field in the UI bench is untried against an inactive app. Tests guard the
main thread's share with `NameFilter.mainThreadMatches`, a debug-only count of matches run on the
main thread, beside `Pane.mainSelectionWork`.
