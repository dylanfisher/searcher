# 0140. A pane on a volume that unmounts goes to the root

- **Date:** 2026-10-30
- **Status:** accepted
- **Amends:** [0049](0049-volume-events.md) (did-unmount took a pane offline with its rows and
  did-mount listed it again in place)

## Context

Dylan, 2026-10-30: "when unmounting a disk, if you had it open in a pane, that pane should
clear and you should be moved to root dir". 0049 kept a pane on a volume that unmounted at its
folder, offline with its rows (0045's `goOffline`, `KeptRows`), and listed it again in place when
the volume mounted. It rejected leaving the folder, since 0045 keeps a share's rows when the
share goes away.

## Decision

- **Did-unmount moves the pane to `/`.** Every pane that isn't a column and shows a folder at or
  under the mount point, by 0049's path rule, navigates to `/`: in list mode its own folder, in
  column mode any column's, so a trail focused above the volume with the volume's column open
  moves too. It is an ordinary navigation (`Pane.navigate`): the load, monitor, patches and a
  pending Go to folder stop, the rows, selection and filter clear, and the folder left goes into
  the history. Back to it fails to list as any missing folder does. Size walks stop first, local
  ones too. A trail whose focused column is already `/` starts again there with no history step,
  which closes the columns right of it.
- **Every tab, split and window.** Panes register with `VolumeEvents` (0049), so panes in
  background tabs and other windows move too, and a split's pane on another volume stays. The
  tab reports the change, so the workspace saves `/`, and a relaunch doesn't restore a folder on
  the gone volume.
- **Any unmount.** The sidebar's or a row's eject, Finder, `diskutil` and a share that goes away
  all reach `NSWorkspace`'s did-unmount, and all move the pane. A share that the system unmounts
  and mounts again moves the pane too: did-unmount means the volume went. A share that stops
  answering without unmounting still goes offline with its rows (0045), which this doesn't change.
- **Will-unmount and will-eject** are unchanged: they stop loads (and for an eject, monitors) so
  the app holds no folder of the volume open.
- **Did-mount** is unchanged: a pane at or under the mount point lists again and asks for a new
  monitor. The panes that left aren't on the volume, so it does nothing to them; it serves a pane
  that went Back to a folder on the volume, and a refused eject.
- **Deleted:** `Pane.volumeIsGone`, which kept a pane offline after an unmount from listing what
  was left at the mount point. No pane stays on a gone volume now. `goOffline` and `KeptRows`
  stay: an `unreachable` failure, `gaveUp` and `volumeGone` still use them.

## Alternatives considered

- **Keep 0049's offline pane** — rejected: Dylan asked for the pane to leave.
- **Close only the columns on the volume** — rejected: Dylan asked for the pane to land at the
  root, and the cut trail would leave the keys in whatever column was left of the volume.
- **Go to the volume's parent or the home folder** — rejected: Dylan asked for the root.
- **Wait a moment before moving, in case a share mounts again** — rejected: the system has said
  the volume went, and a timer would leave a pane on a folder that isn't there.

## Consequences

A Go to folder pending when the volume unmounts is dropped, as any navigation drops it. Back
and Forward entries, saved workspaces and the window's own Back steps can still name folders on
the gone volume; each fails to list when shown, as a deleted folder does. A pane that reached the
volume through a link isn't matched (0049) and stays.
