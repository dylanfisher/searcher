# 0069. Cut and paste: one app clipboard, a cut ends at the next write, Finder's pasteboard shape

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M4.8 adds Cmd-C, Cmd-X, Cmd-V and Cmd-Opt-V for files (`tmp/behavior.md`). Finder has no Cut,
so a cut can't be marked on the pasteboard in a way Finder reads, and Searcher has to remember
it. The pasteboard is the user's, and any app can write it between a cut and a paste. The Edit
menu already had Cut, Copy and Paste items sending AppKit's `cut:`, `copy:` and `paste:`, which
the rename and filter fields must keep for their text ([0068](0068-inline-rename.md)). Copies
and moves run through the app's one queue ([0065](0065-operation-queue.md),
[0067](0067-operations-panel.md)).

## Decision

- **Keys.** Cmd-C Copy, Cmd-X Cut, Cmd-V Paste and Cmd-Opt-V Move Items Here, registered as
  `ClipboardCommands`.
- **One clipboard for the app.** `WorkspaceWindows` makes one `CutState` over the clipboard the
  app passes, the general pasteboard, and every pane's `CommandContext.clipboard` holds it. A
  cut in one window pastes as a move in another, and every list dims the same rows.
- **A cut lasts until the next write.** `CutState` keeps the cut paths and the pasteboard's
  `changeCount` right after the cut wrote them. Paste moves only while the count is unchanged;
  any later write, by Searcher's Copy or by another app, makes Paste copy. A paste that moves
  ends the cut, so a second Cmd-V copies what is on the pasteboard. Pressed again at once, that
  copy reads the sources the move is changing, so the queue refuses it, or, once the move is
  done, it fails with the sources gone; either shows in the operations panel and nothing is
  copied.
- **Move Items Here** moves whatever file URLs are on the pasteboard, cut or not, Finder's
  included, as Finder's Cmd-Opt-V does. It ends a cut too.
- **No question.** Neither paste asks before queueing. Conflicts are asked by the queue as for
  any copy or move. A copy pasted into its own folder takes Duplicate's names and a move into
  its own folder does nothing, both from the queue.
- **Selection.** Pasted items are selected once the pane lists them, as Duplicate selects its
  copies, through `Pane.select(_:whenListedAtSelectionVersion:)`. No name is edited.
- **Pasteboard shape.** One `NSPasteboardItem` per file with its `public.file-url`, as Finder
  writes, a folder's ending in a slash. Whether an entry is a folder comes from the listing, so
  building the URLs reads nothing from the disk on the main thread. The names, one per line, as `public.utf8-plain-text` on the first item, so a text
  field or a text editor pastes the names. Reading goes through `NSURL` with
  `urlReadingFileURLsOnly`, which takes every item's file URL and the file names older apps
  write as `NSFilenamesPboardType`, and ignores web URLs and text. `PasteboardFileClipboard` does both, over any `NSPasteboard`; drag and drop
  (M4.11a) uses it with the drag's pasteboard.
- **Menus.** Edit's Cut, Copy and Paste stay AppKit's text actions. A text field answers them for
  its text; `ListingTableView` answers them by running the command on the item's chord, as it
  already did for Select All, and turns the item off while the command would do nothing. Move
  Items Here is a command item after Paste; a text field doesn't answer its action, so the item
  is off there.
- **Dimmed rows.** A cut entry's cells draw at half opacity in every list and column showing its
  folder, until the cut ends. The list reads the cut names when its rows change and when the cut
  changes, not per cell, and reads the pasteboard's count only while a cut exists. Another app's
  write is noticed when Searcher becomes active again, which ends the cut and undims the rows.

## Alternatives considered

- **Mark the cut on the pasteboard with a private type** — rejected: Finder would ignore it, and
  a later write by another app clears it anyway; the change count tells the same thing.
- **A cut that outlives other writes, as long as its URLs are still on the pasteboard** —
  rejected: the plan asks that any other write make Paste copy, and comparing URL lists after
  each write costs a pasteboard read for nothing.
- **Command items for Cut, Copy and Paste, as Move Items Here** — rejected: a command item has
  `runMenuCommand` as its action, which text fields don't answer, so Cmd-C would stop copying
  text in the rename and filter fields.
- **Poll the pasteboard to undim rows at once** — rejected: a timer on the main thread for a
  cosmetic change; checking when the app becomes active covers writes made in another app.
- **Write `NSURL` objects** — rejected: the text it adds is the URL, not the names Finder gives.

## Consequences

The dimmed rows can stay dimmed after a background app writes the pasteboard while Searcher is
active, until the rows change or the app is activated again; Paste still copies then, since it
checks the count. A file reference URL (`file:///.file/id=…`) on the pasteboard is not
handled on its own; Finder writes path URLs. Names joined by newlines can't show
a name that holds a newline unambiguously; the file URLs are what a paste reads. A paste is one
queued copy or move, so whatever undoes a copy or move undoes a paste.
