# 0036. Open folder links in the pane, through Go to folder, at the link's path

- **Date:** 2026-10-22
- **Status:** accepted

## Context

[0019](0019-pane-model.md) handed every symbolic link to `SystemActions`, as a file, so that the
pane made no file-system call. Opening `/var`, a link to `/private/var`, then opened it in
Finder instead of listing it. A listing describes a link itself, not its target
(`DirectoryEntry`), so the pane can't tell a link to a folder from a link to a file from its
rows. `tmp/behavior.md` has no rule on links.

## Decision

Open on a single selected link calls `Pane.goToFolder` on the link's path, so listing it is the
check, off the main thread, as [0033](0033-history-and-go-to-folder.md) does for a typed path.
Listing a link follows it, through any chain of links.

- A link to a folder moves the pane on its first rows, with a history step, as Go to folder does.
- Not a folder (a link to a file) and not found (a broken link) leave the pane where it was, and
  the link goes to `SystemActions`, as before.
- Any other failure, such as a loop (`ELOOP`) or a folder the user can't read, moves the pane
  into its failed or denied state, as Go to folder does, so the user sees why.
- A pending link open is a pending go: a navigation, Back, Forward or another Go to folder
  cancels it, and a link open cancels a pending go in turn. Only the last request moves the pane.

Choices the plan left open:

- **The pane shows the link's path, not the target's.** Opening `/var` shows `/var` in the path
  bar, and Go to parent returns to `/` with `var` selected. Finder shows `/private/var` instead.
  The link path is what the user chose and what Go to folder already shows for a typed `/var`,
  since `PathInput` takes paths apart by their text (0033); showing the target would take a
  `realpath`, a call per component, and would make Go to parent leave for a folder the user never
  saw. The folder monitor already watches the resolved folder, since FSEvents reports resolved
  paths.
- **A multi-selection doesn't resolve its links.** With several entries selected, folders are
  still skipped and every link goes to the system unresolved, as in 0019: resolving them would
  take a call each, and opening several folders has no meaning in one pane.

## Alternatives considered

- **`stat` the link off the main thread, then navigate** — rejected for the reasons 0033 gave
  for Go to folder: a second file-system call per open, and the target can change between the
  check and the listing. It also needed its own way to drop a late answer next to `goToFolder`'s,
  and that one raced: a Go to folder typed during the `stat` was cancelled when the `stat`
  landed and navigated, and Back then Forward before it landed left the pane where it started,
  so the link opened late.
- **Show the resolved path, as Finder does** — rejected for the reasons above.
- **Stat every link while listing, so the entry carries its target's type** — rejected: a call
  per link on every load, for the rare open; Folders First keeps sorting links with files
  ([0031](0031-view-settings.md)).

## Consequences

Opening a link to a folder costs what a Go to folder costs: the pane keeps its rows until the
first rows of the target arrive, instead of showing the spinner at once. A link to a file pays
one failed `open` of a directory before it goes to the system. A path through a link keeps the
link's path, so `link/..` from inside it is the link's folder, matching Go to folder.

Because a pending link open is a pending go:

- Esc in the Go to folder sheet, which cancels the pending go, also drops a pending link open.
- A slow link open, such as a link into a share that has stopped answering, shows nothing until
  its first rows arrive. Opening a plain file meanwhile doesn't cancel it, since that isn't a
  navigation.

A link to a file inside a privacy-protected folder lands in the denied state at the link's path
instead of opening in its app, because listing it fails with `EPERM` before it can fail with
`ENOTDIR`. This is accepted: the denied state explains the access the app needs to reach it.
