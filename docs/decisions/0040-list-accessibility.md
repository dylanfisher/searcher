# 0040. List accessibility: a label per row on screen, the table's own selection posts

- **Date:** 2026-10-22
- **Status:** accepted

## Context

M1.12 makes the list view usable with VoiceOver. Each row has to read its name, kind, size, date
and download state; selection moves from keys have to be announced; the path bar and filter field
have to be reachable, and a filter's result count announced. The pane owns the selection and
moves it through the registry, so `NSTableView` never sees the keys
([0029](0029-row-movement.md)). A selection can be shown provisionally and settled a few frames
later off the main thread. The not-downloaded badge was its own accessibility element, read after
the name ([0030](0030-not-downloaded-badge.md)). A filter result lands only if it's still the
latest query ([0037](0037-type-to-filter.md)). The main thread does no work per entry (B10).

## Decision

- **Row label.** Each row view gets an accessibility label when the table adds it
  (`tableView(_:didAdd:forRow:)`) and again when a row is refilled in place, so labels are built
  only for the row views on screen, never for every entry. The parts are the text the row's
  name, kind, size and date cells show, read back from them, so the label says what the columns
  say and nothing is formatted twice. They're joined with commas: "Report.pdf, PDF document,
  2 MB, modified Sep 13, 2020 at 12:26 PM". An entry without a size (a folder, a link) leaves the
  size out instead of reading the column's "--".
- **Download state once.** A dataless entry's label ends with "Not downloaded". The badge stops
  being an accessibility element, like the type icon, which repeats the Kind column. That way
  VoiceOver can't read the state twice, once in the row label and once from the badge.
- **Selection announcements come from the table.** Every programmatic
  `selectRowIndexes(_:byExtendingSelection:)` makes `NSTableView` post `selectedRowsChanged`
  itself, synchronously, through `-[NSTableView _sendSelectionChangedNotificationForRows:columns:]`
  (seen with a breakpoint on `NSAccessibilityPostNotificationWithUserInfo` in a plain table). The
  pane's moves reach the table as one `selectRowIndexes` per change of the selected rows, so each
  keyed move (End, Opt-↓, Ctrl-Shift-↓, a type-select key) is announced once, and a key that leaves
  the rows as they are posts nothing. The list posts nothing of its own. Tests count the table's
  `selectionDidChangeNotification`, which comes with the same change.
- **A settle is announced too.** When a provisional selection settles and that changes the
  selected rows (Cmd-A on a provisional selection gains the rows away from the cursor), the table
  posts again. That's a real change to which rows are selected, so it stays.
- **Filter count.** Once the pane's state is `.loaded` with the pane's current, non-empty filter,
  and that filter wasn't announced yet, `FilterBarView.announceResult` posts an announcement:
  "1 item", "2 items", or the same "No items match “text”." line the list shows. Keys typed faster
  than the rows land are announced once, for the query that landed. A patch or reload under the
  same filter isn't announced again. A new folder starts over, so the same query typed there
  before its listing lands is announced.
- **Path bar.** The bar is a group labeled "Path". Its accessibility children are the segments'
  button cells, titled with each folder's full name. A control's element is its cell, so the
  "›" separators' cells are taken out, not the text fields.
- **Posting is injected.** `FilterBarView.postAccessibility` defaults to `NSAccessibility.post`.
  Tests replace it and record what would be posted.

## Alternatives considered

- **Build the label lazily in a `NSTableRowView` subclass's `accessibilityLabel()`** — not done:
  it adds a type to save joining four strings the cells already hold, once per row view added.
- **Format the label's parts again from the entry** — this was the first version. Rejected: it
  formatted each row's date twice, once for the cell and once for the label.
- **Keep the badge as its own element and leave the state out of the row label** — rejected: with
  a row label set, whether VoiceOver also reads the row's children isn't fixed, so the state would
  be read twice or not at all.
- **Post `selectedRowsChanged` from the list after each keyed command** — tried and dropped: the
  table already posts one per `selectRowIndexes`, so every keyed move was announced twice.
- **Suppress the table's post when a provisional selection settles** — rejected: it would mean
  subclassing the table's private notification path, and the settle does change the selected
  rows.
- **Announce the count on each key** — rejected: the plan asks for the count of the rows that
  landed, and a fast typist would hear stale counts.

## Consequences

Moving through cells inside a row with VoiceOver no longer reaches a "Not downloaded" element;
the state is only in the row label. Announcements depend on the pane changing the table's
selection in one `selectRowIndexes` per change; a second call per change would be read twice,
and the tests that count selection changes per key guard that. A patch or load that shifts the
selected rows' indexes also makes the table post. Whether VoiceOver reads a row view's label in
place of its cells is left to Dylan's VoiceOver check.
