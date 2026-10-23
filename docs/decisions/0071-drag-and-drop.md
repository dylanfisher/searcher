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
  one queued move. Promises always copy.
- **A source that stops answering.** Every `FilePromiseReceiver.progressInterval`, 5 s, the
  receiver has the queue read how many bytes the drop folder holds, off the main thread. Once
  `idleTimeout`, 60 s, passes with no new bytes and no file arriving, the files still promised
  count as failed, with the drop folder's path and `ETIMEDOUT`, and the drop goes on with what
  arrived. A drop folder that can't be read ends the wait the same way, failing with its own
  error and path rather than counting as no new bytes. A 4 GB export still being written keeps
  the drop waiting however long it takes. Both are timed on an injected clock.
- **Removing the folder.** The folder is an opaque `FileOperationQueue.DropFolder` that only
  `makeDropFolder` makes, and the queue keeps the ones not yet removed, so `removeDropFolder` can't
  be handed another path. An empty folder is removed. Anything left in it, a file the user
  skipped in a conflict or one that arrived after the wait ended, goes to the Trash first, since
  a promise, such as a file a browser made on demand, may not be made again. A failed trash,
  such as on a volume with no Trash, leaves the folder where it is and is reported. The folder
  is listed through a descriptor opened with `O_NOFOLLOW | O_DIRECTORY`, so a symlink put in its
  place can't point the trash at another folder. A folder is taken out of the queue's set before
  anything else, so removing it twice, by its drop and by the quit, removes it once.
- **Leftovers.** Before it makes a drop folder, the queue removes the empty
  `.searcher-drop-*` and `.searcher-replace-*` folders it isn't using in the target folder, with
  `rmdir` only, so one with anything in it stays ([0065](0065-operation-queue.md)).
- **Quit.** `applicationWillTerminate` removes the folders still pending the same way, off the
  main thread, waiting at most 1 s. That trashes whatever is in them, half-written files a source
  app is still writing included, and abandons the drops still waiting: nothing they were
  receiving is moved into its target.
- **Failures show in the operations panel.** A folder the queue couldn't make (a read-only
  target), a promised file that failed or never came, and a folder that couldn't be removed are
  reported with `FileOperationQueue.report` as one failed `FileOperation.receive` row per drop,
  with each error and its path, and logged under the `drop` category. The row is named after the
  file when one file failed, else "Drop from <app>", the app active during the drop, which is the
  one the drag came from. A source that stopped answering reads as "“<drop folder>”
  stopped answering." under that name, since an error's path must be a path.
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
- **Delete what is left in the drop folder** — rejected: it would lose a file the user skipped,
  and a source may not be able to make it again.
- **Only log a failed promise** — rejected: AGENTS.md asks to fail loudly, and the log is out of
  the user's sight.

## Consequences

Paths are placed by their text: a path through a symlink or a firmlink takes the volume its text
names, so a drag between `/Users/someone` and `/System/Volumes/Data/Users/someone` copies where
Finder would move. Two mount points that differ only by case, such as `/Volumes/Backup` and
`/Volumes/backup`, compare equal, so a path on one can be placed on the other and a drop between
them moves where Finder would copy; the queue still reads each item's real volume, so the move
is done as a copy and a delete. A drop made in the moment between a mount and the table's next
read copies from the new volume until the read lands. A promise that never answers holds its
drop for 60 s after the last byte; a source that stalls for longer mid-file is cut off, and a
file written after that lands in the hidden folder and goes to the Trash with
it. A folder left by a crash, or by a quit that took longer than 1 s to remove it, is removed
the next time a drop or a replace makes a folder beside it, if it is empty; one with files in
it stays for the user. Undo of a drop is whatever undoes a queued copy or move.
