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
  ⌘K and ⌘W close Open Quickly; Esc closes it and changes nothing. (Amended 2026-10-25: Open
  Quickly has ⇧⌘P beside ⌘K in the same way ([0087](0087-palette-window.md)), and both panels
  open on the screen of the window that opens them, centered near its top or where the last one
  was dragged.)
- **Candidates.** The rows of the command pane, the focused column in column view, as its
  listing has them when the palette opens: hidden entries and the filter as the pane shows them,
  in its sort. Nothing nested and no file-system call. Each item is titled with the name, its kind
  beside it, and its row shows the type's icon, as the list does. The listing is a snapshot: a
  row that arrives while the palette is open isn't listed, and choosing one that has left the
  rows since does nothing: the selection, the scroll and the selection history stay as they
  were. (Amended 2026-10-25, Dylan: "multi line names in cmd p are hard to read, too tight
  leading etc". A name too long for one line wraps, in both palettes, and its row grows to hold
  it: 3 pt between the lines beyond the font's leading, and 7 pt above and below, where the row
  had stayed 32 pt and the lines overflowed it. A title that fits keeps the 32 pt row. The title
  wraps at the room the icon, the chord and the detail leave; the detail keeps up to a third of
  the row beside the first line, so a long name doesn't squeeze its kind to a letter. Each row's
  height comes from one never-shown cell that measures the title's height for its wrap width
  without a layout pass, about 1.4 ms for 50 rows in a debug test build. Wrapping rather than
  truncating keeps the whole name in view, which is what the list is searched for.) (Amended
  2026-10-26, Dylan: "cmd+p in column mode should search the current directory and the
  highlighted directory". In column view, when the folder selected in the focused column shows
  its column to the right (`ColumnTrail.selectedFolderColumn`, the rule New Folder and Paste
  share, [0111](0111-column-view-target-folder.md)), its rows are listed too, after the focused
  column's, from the
  listing that column already has: still no file-system call, and a column that hasn't listed
  yet adds nothing. A preview, a file or several rows selected, or nothing selected adds
  nothing either, since no column shows right of the focused one. Their detail is the kind
  followed by "in" and the folder's name, "PNG image in png", so a name that is in both
  folders reads apart; the focused column's rows keep the kind alone. The placeholder names
  both folders: "Go to Item in images and png". Nothing deeper is listed: the folder is the one
  the columns already show, as Dylan's screenshot shows.)
- **Ranking: the match alone.** Entries are a kind of their own with no kind or frecency bonus,
  so they fall in one bucket and `FuzzyMatcher.best` ranks them by score, then the shorter name,
  then pane order. Frecency counts folders visited, not rows chosen, and a bonus for folders over
  files would rank a worse folder match above the file typed. An empty query lists the first 50
  rows in pane order. (Amended 2026-10-26: the selected folder's rows in column view are ranked
  with the same scores, in the same bucket, after the focused column's rows in pane order. So an
  equal score ranks the shorter name first, and at an equal name the focused column's row first,
  as the folder the keys are in. A penalty for the other folder's rows was rejected: a better
  match there would rank below a worse one in the focused column, which is what the fuzzy match
  exists to avoid.)
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
  - **The keys go to the pane.** (Amended 2026-10-26, Dylan: "after using cmd+k to go to a file
    or directory, always put focus back into that pane".) Once the row is selected, the pane's
    table, or the focused column's, takes the keys, even if the sidebar or the filter field had
    them, as a folder chosen in Open Quickly gives them ([0087](0087-palette-window.md)): the
    jump is a choice of a row there, and the keys are what act on it next. The filter stays as
    it was.
  - **A row of the selected folder**, in column view (amended 2026-10-26), runs
    `ColumnTrail.jump(to:inColumnOf:)`: that column takes the keys, as a click in it does, which
    is a step of the pane's Back and Forward history as any move between columns is (0041), and
    the row is selected there by `Pane.jump(to:)`, one `.once` step of that column's selection
    history, centered. The focused column keeps its selection, so the column stays. A column
    closed since the palette opened, or a row gone from it, does nothing.
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
