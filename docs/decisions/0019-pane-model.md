# 0019. Pane model: selection by name, commands as bindings, no file-system calls

- **Date:** 2026-10-21
- **Status:** accepted

## Context

A pane has to act on key presses (Open, Go to parent, ↑ / ↓) without touching the file system, so
that Browser stays testable without a window and AGENTS.md's rule against main-thread I/O holds
by construction. [0010](0010-command-registry.md) left open how a command reaches the pane it acts
on. [0017](0017-list-view-columns.md) asks the pane to own the sort and the selection.

## Decision

`Pane` holds the location, a `ListingState`, the sort and the selection. It lists through
`ListingService`, passes its own sort to each load so listings arrive sorted off the main thread,
and opens files through `SystemActions`. It stops its `FolderMonitoring` object when it navigates;
whoever starts the monitor assigns it to `Pane.monitor` and passes its changes to `Pane.apply`
([0021](0021-one-pane-window.md)).

The selection is a set of `ExactName`s, so two canonically equivalent names stay distinct. Names
the listing lacks are dropped when a load finishes (`full`), not on a partial listing. Go to parent
selects the folder it left by name, which is how the selection survives the load.

A command set is an enum with a `bindings` list: each `CommandBinding` pairs a `Command` with a
handler that takes a `CommandContext` (the focused pane). `AppCommands.sets` is the one list of
sets; its `registry()` builds the registry the key router uses.

Choices the plan left open:

- Open on a symbolic link goes to `SystemActions`, as a file. Telling a link to a folder from a
  link to a file takes a `stat`, and the system resolves it.
- Open with several rows selected opens the files and skips folders.
- ↑ / ↓ with nothing selected selects the first row going down and the last going up; with several
  rows selected they do nothing.
- Regaining focus re-lists unless a load is already running. The old rows stay until the new
  listing arrives, so the table doesn't flash.
- A load that fails with EPERM, which privacy protection (TCC) returns, puts the pane in the
  `denied` state; every other error, EACCES from Unix permissions included, is `failed`. Full
  Disk Access lets the app into the first and not the second, so only `denied` offers it. The
  errno is read once, in `ListingError.reason` (`privacyProtected` against `permissionDenied`).
- A listing that arrives in a sort other than the pane's (the sort changed during the load) is
  re-sorted on the main actor, the same cost as a header click.

## Alternatives considered

- **A closure on `Command`** — rejected: `Command` stays plain data that settings and menus read,
  as 0010 chose.
- **Selection as `Set<String>`** — rejected: `String` equality is canonical equivalence, which
  would merge two files that a case-sensitive or SMB volume holds separately.
- **`URL(fileURLWithPath:)` without `isDirectory`** — rejected: it stats the path.
- **The pane starting its own `FolderMonitor`** — rejected: the monitor's constructor belongs to
  M0.6, and a protocol keeps the pane testable with a stub.

## Consequences

The view controller can read rows, sort and selection from the pane and report header clicks and
selection changes back. `Pane` has no `deinit`: a pane dropped without navigating leaves its load
running until it finishes; its updates reach no one, because the handler holds the pane weakly.
