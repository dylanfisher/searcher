# 0062. File copier: a new name only, nothing partial left, progress every 100 ms

- **Date:** 2026-10-22
- **Status:** accepted

## Context

[0058](0058-copy-engine.md) chose `copyfile(3)` with `COPYFILE_ALL | COPYFILE_CLONE |
COPYFILE_NOFOLLOW`, a status callback for progress, pause and cancel, and `setattrlist` for the
creation date. Building `FileCopier` on it raised questions the record doesn't answer. Checked on
macOS 26.6 against the boot volume and an HFS+ disk image:

- A recursive copy onto an existing folder copies into it, as `dst/name`, with or without
  `COPYFILE_EXCL`. A single file onto an existing one fails with `EEXIST`: `COPYFILE_CLONE`
  implies `COPYFILE_EXCL`.
- A failure in a recursive copy reaches the callback as `COPYFILE_ERR` with `errno` set. Returning
  `COPYFILE_CONTINUE` skips the entry and the copy returns 0, or, on `ENOSPC` during data, retries
  the write without end. After a cancel, the callback also gets an error with `ECANCELED`.
- A recursive copy stopped by an error or a cancel leaves the entries it finished, and a folder
  for one it hadn't started. A single file it stops is removed.
- `COPYFILE_STATE_COPIED` counts the current file only, and stays 0 for a clone.
- `setattrlist` can't set the creation date of a locked copy (`UF_IMMUTABLE`): `EPERM`.

## Decision

- **New names only.** `copy` throws `exists` if the destination is there before it starts. The
  operation queue decides what to do about a name that's taken.
- **One item per call, nothing partial.** On a failure or a cancel, the copier removes what it
  wrote at the destination with `removefile(3)`. Items finished by earlier calls stay. If the
  removal fails, its error is the one thrown, since it says what is left on disk.
- **Every error stops the copy.** The callback returns `COPYFILE_QUIT` on `COPYFILE_ERR` and keeps
  the first error, mapped by `FileOperationError(errno:path:)`. The path is the entry that failed:
  its destination for no space and exists; its source for denied access unless the source is
  readable, then the destination; its source otherwise.
- **Creation dates for every entry.** Files and symlinks get theirs when `copyfile` finishes them,
  folders after their entries. A locked copy is unlocked for that one call. A volume that refuses
  the date fails the copy.
- **Progress.** Bytes count each regular file's logical size when it finishes, plus the current
  file's `COPYFILE_STATE_COPIED`, so a folder ends at `TreeSizeWalker`'s total. The first change
  is reported at once and later ones at most every 100 ms, on the copying thread; the final
  totals are `copy`'s return value, so no report is sent early to deliver them.
- **Pause and cancel.** One `FileCopier` per operation. Pause blocks the callback on a condition
  after the progress report; cancel wakes it and every later callback returns `COPYFILE_QUIT`.
  A cancel is final: every later `copy` on that copier throws `CancellationError` before it
  writes.

## Alternatives considered

- **Copy to a temporary name and rename into place** — rejected for now: it would also close the
  window between the existence check and the copy, but it leaves a second name on disk to clean
  up after a crash, and the rename is one more step that can fail. The window is small, and the
  queue (M4.4a) runs one copy at a time per volume.
- **Leave partial entries for the queue to remove** — rejected: only the copier knows whether the
  destination was there before it started, and every caller would need the same cleanup.
- **Deliver the final totals as a last report** — rejected: a copy that ends within 100 ms of a
  report would break the interval, and callers already wait for `copy` to return.
- **Skip the creation date when the volume refuses it** — rejected: that is a silent fallback.
  If SMB or exFAT refuse it, M4.13 shows it and this changes then.

## Consequences

A cancelled tree copy costs a recursive delete of what it wrote. A partial tree with a locked file
in it can't be removed (`removefile` gets `EPERM`), so that cancel throws `permissionDenied` with
the path and leaves the copy. Copying into a name that something else creates between the check
and the copy can put the item inside that folder. Each entry costs an `lstat` of its source and a
`setattrlist` on its copy.
