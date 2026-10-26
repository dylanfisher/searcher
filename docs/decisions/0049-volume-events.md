# 0049. Volume events: panes register themselves, monitors stay through will-unmount

- **Date:** 2026-10-22
- **Status:** accepted
- **2026-10-25:** The sidebar's volume list reads the mounts again on each event too, and its
  eject runs will-unmount before it asks the system; see [0108](0108-sidebar-locations.md).

## Context

M2.4 has to take panes on a volume that went away offline with their rows
([0045](0045-cached-rows-first.md)), list them again when it comes back, and keep the app from
blocking an eject. The app hears of mounts from `NSWorkspace`, which Browser can't import. The app
has no list of its panes: windows, tabs, splits and columns each make panes of their own. A forced
unmount revokes the vnode a network folder's watch holds ([0020](0020-folder-monitor.md)), and the
watch reported that as a change, so the pane listed a folder that was gone.

The step's spec said will-unmount must close the watch's descriptor, or a plain `hdiutil detach`
would fail. That premise was false. `VnodeWatch` opens with `O_EVTONLY`, which exists so that a
watch doesn't keep a volume from unmounting. On a disk image, a plain detach succeeds with the
watch open and revokes its vnode; an `O_RDONLY` descriptor makes the same detach fail with
"Resource busy". What can block an eject is a load, which has the folder open while it reads.

## Decision

- **Forwarding only in the app.** `VolumeNotifications` passes the volume's path from
  will-unmount, did-unmount and did-mount to `VolumeEvents` and does nothing else.
- **Panes register themselves.** `Pane.init` adds the pane to `VolumeEvents`, which holds every
  pane weakly. A pane is on a volume when `isPath(_:atOrUnder:)` says its path is at or under
  the mount point. Columns are panes, so each column acts on its own; a column-mode owner, which
  has no folder of its own, ignores the events.
- **Will-unmount** cancels running loads on the volume. Monitors stay, so a refused unmount
  leaves the pane watched. A cancelled load's pane lists again on focus.
- **Did-unmount** cancels the load, stops the monitor and waiting patches, and goes offline
  through 0045's `goOffline`, keeping the rows as `KeptRows`. Until the volume mounts or the
  pane leaves, `reload` and a re-list do nothing, so focus or a late patch can't replace the
  offline state with a listing of the folder left at the mount point.
- **Did-mount** clears that, stops any monitor still running, moves the pane's
  `monitorGeneration`, and calls `reload`, the pane's existing load path. `PaneViewController`
  and `ColumnViewController` start a monitor when the generation moves, as they do when the
  location changes. Closed panes ignore every event.
- **Revoke.** A `.revoke` event cancels the `VnodeWatch`'s source, which closes the descriptor,
  then calls `onRevoke`, which defaults to nothing. `FolderMonitor` reports no `relist` for it.
- **One path rule.** `isPath(_:atOrUnder:)` in Base replaces the copies in `ListingService`
  (`VolumeIdentity.holds`) and `FolderSizeCache`. `FolderMonitor.change(for:in:)` and
  `FolderSizeService` keep their own checks, which compare UTF-8 bytes against a prefix they
  build once per batch.
- **Test images.** `DiskImage` attaches with `-nobrowse` at a folder in its own temporary folder,
  named with the process ID. Once per process it force-detaches images whose folder names a
  process that is gone, so a test process that crashed doesn't leave images attached.

## Alternatives considered

- **Close the monitors at will-unmount** — the spec's version. Rejected: it doesn't help the
  unmount, and when the unmount is refused the pane is no longer watched.
- **Walk windows, tabs, layouts and column trails for panes** — rejected: the app holds no
  workspace yet, and every new place that makes panes would need to join the walk.
- **A `VolumeEvents` instance passed to each pane** — rejected: it changes `Pane.init` and every
  caller of it.
- **Report `relist` on revoke** — rejected: the folder is gone with its volume, and the load
  would show "not found" over the offline state.
- **Make the pane leave its folder on unmount** — rejected: 0045 keeps the rows for a share that
  goes away, and a volume that comes back lists in place.

## Consequences

A pane whose load was cancelled at will-unmount, on a volume that then stays mounted, shows what
it had until it gains focus. Panes are matched by path text, so a pane that reached the volume
through a link isn't matched. Every pane hears every event, so tests that send volume events use
mount points no other test uses.
