# 0034. Type-to-select: a prefix match in display order on the main thread, Space while typing

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M1.7 builds type-to-select (`tmp/behavior.md`): typing letters selects the first name in display
order that starts with the typed text, no match keeps the selection and beeps, and the text
resets after 1 s without a key. Space within 1 s of a type-select key adds a space to the query;
otherwise Space is Quick Look, which M1.9 binds as a registry command. AppKit's own type-select
is off, since it made a row view for each row it checked ([0025](0025-sort-off-main.md)). Names
are folded once per listing for matching ([0028](0028-folded-names.md)), and hidden entries have
no row ([0031](0031-view-settings.md)). Each key is held to B6, 16 ms on W2.

## Decision

- **Match.** `TypeSelect.firstRow(startingWith:in:)` folds the query with `NameSortKey.fold` and
  walks the listing's rows in display order, comparing each row's folded name's UTF-8 bytes with
  `utf8.starts(with:)`. The first row that starts with the query wins, so the same text selects
  different rows in different sorts. Hidden entries have no row, so they never match. Typing "ré"
  selects "Resume", and "가" selects "각".
- **On the main thread.** In a release build, a walk of 99,000 W2-shaped rows (100k names, the
  1% dot files hidden) took a median of 0.46 ms with no match and 0.30 ms for a match three
  quarters down, over 30 runs each. That is a thirtieth of B6, so there is no worker and no
  latest-key-wins state.
- **Selecting.** `SelectionCommands.selectFirstRow(startingWith:in:)` selects the matched row
  alone with the cursor and anchor on it, as a plain move does, through `Pane.select`, which
  looks up the one name. No match returns false and changes nothing; the table beeps.
- **The query.** `TypeSelect` holds the text typed since the last pause and when the last key
  came, on an injected `Clock`: `ContinuousClock` in the app, `ManualClock` in tests. A key
  `resetInterval` (1 s) or more after the last one starts a new query. A key that matches nothing
  still joins the query, so typing on after a miss keeps missing until the pause.
- **What ends a query.** Besides the pause, any command run from a key, a menu item or a key the
  Quick Look panel hands back ends it, since all three run through `ListingTableView.run`. A
  change of the pane's location ends it too, however it happens (a command, a double-click, a
  path bar click). As in Finder, "b", ↓, "c" searches for "c", not "bc", and "d", Cmd-↓, "s"
  starts a new query in the folder just opened.
- **Repeated letters.** A repeated letter doesn't cycle through the names that start with it:
  "rr" searches for "rr". Cycling would make a name with a double letter ("rr-notes") reachable
  only by pausing, and ↓ already steps to the next row.
- **Which keys.** `ListingTableView.keyDown` takes a key in this order:
  1. Space with no modifiers while a query is being typed (`TypeSelect.isTyping`) joins the
     query, ahead of any command on Space.
  2. A chord bound to a command runs it, so a command on a plain letter outranks type-select.
  3. An unbound chord with Command, Control or Option beeps ([0027](0027-key-dispatch.md)).
  4. An unbound printable key with Shift or nothing else goes to type-select
     (`TypeSelect.text(for:)`). Shift counts, since it types capitals and punctuation, and the
     fold drops case.
  5. Anything else still goes to `super`.

  Space at any other time, including the first key of a new query, goes through the registry
  and runs whatever is bound to it. A letter typed with Option (ø, ß on a US keyboard) beeps
  rather than typing, since an unbound Option chord beeps ([0027](0027-key-dispatch.md)); a name
  that starts with one is reached with the arrows.
- **Bench.** The UI bench's launch that presses ↓ waits 1 s twice, each time typing the first
  12 characters of the last row with an ASCII name on W2, sorted by name, and times each key to
  its frame as one B6 case. That row sorts after most rows, so each key walks most of the
  listing.

## Alternatives considered

- **Match off the main thread, latest key wins.** Rejected: the walk costs under 0.5 ms on W2,
  and a worker would add a hop and a race with the next key for nothing.
- **A binary search on the name order.** Rejected: it finds the first match in name order, not
  display order, so it would be wrong in every other sort.
- **`hasPrefix` on the folded names.** Rejected: it compares characters, and a decomposed Hangul
  syllable is one character, so 가 wouldn't prefix 각 (0028).
- **Type-select before the registry for every printable key.** Rejected: a user binding on a
  plain letter (behavior item 11) would never run.
- **Drop a key that matches nothing from the query.** Rejected: the next key would extend a
  query the user didn't type, and could select something unrelated.

## Consequences

Unicode letters the fold doesn't decompose stay apart: "Ünïcødé" folds to "unicøde", so
"unicode" doesn't select it. Keys typed through an input method (Japanese, Chinese) arrive as
marked text, not key events, and the table doesn't take them, so those names can be reached
only by typing a character that a key produces directly. A query that turns out to have no
match beeps on each further key until the pause. With more than 100k rows the walk grows
linearly; at about 5 ms per million rows it stays inside B6 to about three million.
