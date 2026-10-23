# 0071. Drag and drop: Finder's copy and move rules from a mount table, promises through the queue

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M4.11a lets rows drag out as files and lets files and file promises (Mail, Photos) drop into a
pane or onto a folder row, with Finder's rules: an item on the target's volume moves, one from
another volume copies, Option copies, Command moves. AppKit asks a destination to validate a drop
every time the pointer moves, on the main thread, so the volume check can't call `statfs`: one on
a share that stopped answering blocks for minutes ([0038](0038-slow-volumes.md)). Copies and moves
run through the app's one queue ([0065](0065-operation-queue.md)), which refuses a folder moved
into itself and paths in use. A promised file is written by the source app, outside the queue,
to a folder the receiver names. Cut and paste already read and write Finder's pasteboard shape
([0069](0069-cut-and-paste.md)).

## Decision

- **Mount table.** `MountTable` (Browser) holds every mounted volume from the kernel's mount
  table (`VolumeIdentity.mounted`, `MNT_NOWAIT`), read on a `BlockingCallThread` when the table is
  made and again after each mount and unmount that `VolumeEvents` reports. A path's volume is the
  longest mount point it is at or under, compared as `FileOperation.comparable` gives them,
  without case and with Unicode normalized. The app makes one, in `WorkspaceWindows`, and every
  list gets it through the pane's window link, as the clipboard goes.
- **The operation.** `DropOperation` reads the keys from the drag's allowed operations, which
  AppKit narrows by the keys held: copy alone (Option) copies, generic alone (Command) moves,
  and with no keys a drop moves only when every item is on the target folder's volume. A path on
  no known volume counts as another volume, so it copies. Link alone (Command-Option, Finder's
  alias) drops nothing: Searcher makes no aliases. A source that allows only a copy copies.
- **Refusals before the queue.** A drop into an item itself or into a folder inside it is
  refused while the pointer is over it, with the check the queue's plan makes
  (`FileOperation.source(holding:among:)`). A drop whose items are all in the target folder
  already does nothing, keys or not; Finder's Option-drag duplicate in place is not copied.
- **Where it goes.** A drop on a folder row (Kind "Folder", not a package such as an app) goes
  into that folder; anywhere else, on a file row, between rows or below them, the drop is
  retargeted to the whole list and goes into the pane's folder. In column view each column is a
  list, so a drop goes into that column's folder.
- **One queued operation, no question.** A drop queues one copy or move of every item, as Paste
  does, without the confirm that Copy to Other Pane asks (`tmp/behavior.md`). Conflicts are
  asked by the queue as for any copy or move. Items dropped into the pane's folder are selected
  once the pane lists them, through `FileCommands.perform`, as pasted items are; a drop on a
  folder row selects nothing, since the items aren't in the folder shown.
- **Promises through the queue.** For a drag with no file URLs and file promises,
  `FilePromiseReceiver` asks the queue for a hidden `.searcher-drop-<UUID>` folder in the target
  folder, calls the promises in to it (readers on an `OperationQueue`, off the main thread), and
  once every promised file has arrived or failed, moves the ones that arrived into the target as
  one queued move, then has the queue delete the folder with anything left in it. Promises
  always copy. A file that fails to arrive, and a failure to make or delete the folder, is
  logged under the `drop` category.
- **Dragging out.** A row drags as one pasteboard item holding its file URL, a folder's ending in
  a slash, built from the listing (`ClipboardCommands.fileURL(of:in:)`,
  `PasteboardFileClipboard.item(for:)`), so starting a drag reads nothing from the disk. Unlike
  Copy, a drag adds no names as text. The rows allow copy, move, generic and link, inside the app
  and out, so Finder applies its own keys, Command-Option making an alias. `.delete` is left out,
  so the Dock's Trash moves the items itself rather than asking Searcher to.

## Alternatives considered

- **`statfs` each item while validating** — rejected: validation runs on the main thread on every
  pointer move, and one call on a dead share would block it.
- **Read the mount table on every drop** — rejected: `getmntinfo` doesn't wait on a volume, but
  it is still a file-system call on the main thread, which AGENTS.md rules out, and the table
  changes only when a volume mounts or unmounts.
- **Receive promises straight into the target folder, as Finder does** — rejected: the source
  app would write past the queue, so a name already taken would be the source app's to settle,
  often by replacing the file, and nothing would select what arrived.
- **Names as text on the first dragged item, as Copy writes** — rejected: the table asks for
  each row's item alone, so the first item can't know the others' names without building every
  item once per row.
- **Make an alias for Command-Option, or copy instead** — rejected: aliases are not in the plan,
  and a copy would do something the keys didn't ask for.

## Consequences

Paths are placed by their text: a path through a symlink or a firmlink takes the volume its text
names, so a drag between `/Users/someone` and `/System/Volumes/Data/Users/someone` copies where
Finder would move. A drop made in the moment between a mount and the table's next read copies
from the new volume until the read lands. A promised file whose source never calls the reader
leaves the drop waiting and its hidden folder in place until Searcher quits; the folder is not
cleaned up at the next launch. Files a promise skipped, or the user answered skip for, are
deleted with the hidden folder; the source app still has them. Undo of a drop is whatever undoes a
queued copy or move.
