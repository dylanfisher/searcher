# 0101. Go to Item: the palette over the focused pane's rows, a jump that centers the row

- **Date:** 2026-10-25
- **Status:** accepted

## Context

Dylan asked on 2026-10-25 for "a command + p command (alternate cmd + shift + k) that will be a
fuzzy search to move selection to a file/folder in the current pane (only searches the current
pane, nothing nested, and just jumps to that position or selects the folder). it should place
selected item scrolled so it's centered vertically". The ⌘K palette
([0087](0087-palette-window.md), [0085](0085-palette-ranking.md)) already has the window, the
matcher ([0079](0079-fuzzy-match.md)) and the highlighting. Type-to-select
([0034](0034-type-to-select.md)) only matches a name's start. Finder has no such command.

## Decision

- **The command.** `WindowCommands.goToItem`, "Go to Item…" on ⌘P and ⇧⌘K. Neither chord was
  bound: the app has no Print item, and the registry refuses a chord two commands claim. Its item
  sits in the Go menu under Open Quickly, showing ⌘P. Like Open Quickly it runs while a text
  field such as the filter has the keys, and Open Quickly lists it.
- **The palette in another mode.** The same `PaletteWindowController` and `Palette`, with one
  source, `EntrySource`, in place of Open Quickly's four. The field's placeholder says
  "Go to Item in <folder>" and VoiceOver calls the panel "Go to Item". ⌘P, ⇧⌘K and ⌘W close it, as
  ⌘K and ⌘W close Open Quickly; Esc closes it and changes nothing.
- **Candidates.** The rows of the command pane, the focused column in column view, as its
  listing has them when the palette opens: hidden entries and the filter as the pane shows them,
  in its sort. Nothing nested and no file-system call. Each item is titled with the name, its kind
  beside it, and its row shows the type's icon, as the list does. The listing is a snapshot: a
  row that arrives while the palette is open isn't listed, and choosing one that has left the
  rows since does nothing: the selection, the scroll and the selection history stay as they
  were.
- **Ranking: the match alone.** Entries are a kind of their own with no kind or frecency bonus,
  so they fall in one bucket and `FuzzyMatcher.best` ranks them by score, then the shorter name,
  then pane order. Frecency counts folders visited, not rows chosen, and a bonus for folders over
  files would rank a worse folder match above the file typed. An empty query lists the first 50
  rows in pane order.
- **Choosing a row** runs `Pane.jump(to:)`: the entry is selected alone with the cursor on it, as
  a click selects it. A folder is selected, not opened, and a file isn't opened.
  - **One step of the selection history** ([0077](0077-selection-history.md)): the jump is a
    `.once` change, so ⌘U goes back to the selection before it.
  - **A click, not a key** ([0094](0094-column-open-delay.md)): in column view the folder's
    column, or the file's preview, follows at once. The jump is one deliberate choice, as a click
    is; the pause exists for held and repeated keys, which a jump never sends.
  - **Centered.** `Pane.centeringRequest` goes up, and the list, or the column's list, scrolls
    the cursor's row to the middle of the rows on screen in the same pass that shows the
    selection, below the list's column header. `NSClipView.constrainBoundsRect` clamps it, so a
    row near the top or bottom sits as near the middle as the ends allow. A jump to the row
    already selected still centers it.
- **Off the main actor.** The source makes the first 50 rows' items on the main actor, which is
  all an empty query shows, and the rest in a detached task as the palette opens; until then a
  query is ranked over the first 50. Closing the palette cancels the task. With one source the
  ranking skips the set that drops items an earlier source handed over, which only matters
  between sources.

## Performance

Measured once with a throwaway test in a release test build
(`./scripts/test -c release -Xswiftc -enable-testing`), on a loaded machine, over a pane of
100,000 files with names like "invoice_40213 photo.pdf": preparing every row's item, off the main
actor, took 34 ms; ranking a key took 13–15 ms for nine queries of one to eleven letters, of which
`best` was 4–6 ms. The set of item IDs that the ranking used to build took 32–50 ms on its own,
which would have spent B11's 50 ms per key before the frame; that is why one source skips it. Not
benched: the UI bench's `palette` scenario still times Open Quickly over 50k folders.

## Alternatives considered

- **Extend type-to-select** — rejected: it matches the start of a name, by design, and shows no
  list of what matched.
- **Add the pane's rows to Open Quickly** — rejected: Dylan asked for a search of the current
  pane only, and its rows would crowd out the folders and commands.
- **Rank with frecency or a bonus for folders** — rejected above.
- **Count the jump as a key**, waiting out the column-open pause — rejected: the pause keeps a held
  key from opening a column per row, and the folder's column would show 120 ms late for no reason.
- **Center from the window, after the jump** — rejected: the list would first scroll the row into
  view and then center it, two scrolls in one pass, and the window would need to reach into the
  focused column's list. A request counter on the pane reaches the list that shows it, in list
  and column view alike.

## Consequences

The palette's `Kind` has a fourth case and `PaletteItem` an icon type, which only entries set.
`Palette.rank` now trusts a single source not to hand over the same item twice, as every source
does. A UI bench scenario for Go to Item over 100k rows would time the key to the frame; it isn't
added here.
