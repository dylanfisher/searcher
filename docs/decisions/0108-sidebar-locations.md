# 0108. Sidebar Locations: Finder's default volumes, followed live, with eject

- **Date:** 2026-10-25
- **Status:** accepted

## Context

Dylan, 2026-10-25: "sidebar should have a locations feature, like finder (show network drives,
etc)" and "favorites, locations, and tags should all be configurable to be hidden/turned off".
The sidebar has Favorites and Workspaces ([0107](0107-sidebar-favorites.md)), each with a View
menu toggle. The app hears of mounts from `NSWorkspace`, forwarded to Browser's `VolumeEvents`
([0049](0049-volume-events.md)), and `MountTable` already reads the kernel's mount table
(`VolumeIdentity.mounted`, `getmntinfo` with `MNT_NOWAIT`) on a `BlockingCallThread` after each
event ([0103](0103-column-trail-from-the-root.md), [0038](0038-slow-volumes.md)). What can keep
a volume from unmounting is a load holding a folder open, not a watch (0049). Tags needs
search, which is on hold.

Finder's sidebar settings (Finder ▸ Settings ▸ Sidebar) by default list under Locations:
External disks, CDs, DVDs and iOS Devices, Cloud Storage and Connected servers, all on; the
Mac itself, Hard disks and Bonjour computers off. Hard disks covers every disk on an internal
bus, the startup disk with it, so the startup disk isn't listed. A volume mounted
`MNT_DONTBROWSE`, such as the system's Data and VM volumes, isn't listed under any setting.

## Decision

- **A Locations group between Favorites and Workspaces,** as in Finder. It lists the volumes
  Finder's default settings list: every browsable volume that is a share, removable,
  ejectable, or not on an internal bus, which takes in disk images; not the startup disk or
  another internal disk (`SidebarVolume.isShown`). There is one toggle for the group, not one
  per kind of volume as in Finder. Network browsing, Cloud Storage, iCloud Drive and the Mac
  itself aren't listed: the app has none of them. The group shows only while it has a volume,
  so the default sidebar of a Mac with nothing attached is unchanged.
- **A share is listed by its mount point.** Finder lists a connected server and shows its
  shares inside it; the app can't list a server, so each mounted share is its own row, named by
  its mount point's last component (`/Volumes/main` is "main").
- **Read off the main thread, asking no share.** `SidebarVolume.mounted` reads the mount table
  as `MountTable` does, then asks each browsable volume on this machine its localized name and
  whether it is the root, internal, removable or ejectable (URL resource values). A share is
  asked nothing, since one that has stopped answering would hold the read; its name comes from
  its mount point. It runs on a `BlockingCallThread`. The rows keep the mount table's order.
- **Live, in every window.** One `SidebarVolumes` is shared by every window, as `Favorites` is.
  It adds itself to `VolumeEvents`, which reads it again on each did-mount and did-unmount, as
  it reads mount tables again; the list runs its observers when what it lists changes, and each
  sidebar reloads.
- **Rows.** Finder's sidebar glyph, chosen with no read of the volume and loaded as 0107's are:
  `SidebarServerDrive` for a share, `SidebarRemovableDisk` for an internal-bus card or disc,
  `SidebarInternalDisk` for another internal disk, and `SidebarExternalDisk` for a disk off the
  internal bus and for a disk image; SF Symbols (`externaldrive`,
  `externaldrive.connected.to.line.below`) show until they are read, or if the bundle lacks one.
  A missing glyph falls back silently, as 0107 says. An optical disc shows the removable-disk
  glyph, since nothing in `SidebarVolume` says it is optical media, though the bundle has
  `SidebarOpticalDisk`. Colored and sized as 0107's.
  The row also has the name, and Finder's eject
  button on each row that can be ejected (`canEject`: a share, a removable or ejectable disk,
  or one not on an internal bus). (Amended 2026-10-26, Dylan: "some icons are still different
  compared to searcher (e.g. eject)" and "eject icon should hover darker color".) The button
  shows Finder's filled glyph, `eject.fill`, at the size AppKit gives the row's symbols, with
  no fill under it: tertiary label color at rest, secondary under the mouse, the label color
  pressed and quaternary while off; on an emphasized row, the selected row's text color at those
  levels. It is a `HoverButton` with the `.glyph` look ([0110](0110-interaction-states.md)).
  Every listed row can be ejected, as in Finder's default sidebar. A click or Return shows the
  volume's mount point in the window's focused pane (`Pane.navigate`), as a favorite folder's
  click does.
- **Eject.** The eject button and the row's context menu item, `Eject “name”` as Finder titles
  it, call `SidebarVolumes.eject`. It first calls `VolumeEvents.willEject` for the volume: the
  loads, size walks and folder monitors of panes on it stop, so the app holds none of its
  folders open (0049), since the system's will-unmount notification may come only once the
  unmount is under way. File operations go on: a copy with files open on the volume makes the
  system refuse the eject as busy, and the alert shows, as Finder refuses to eject a disk in
  use. Then it runs the ejector on a `BlockingCallThread`: `FileManager.unmountVolume` with no
  system UI. The row leaves when the system reports the unmount. A pane that opens a folder on
  the volume while the eject runs can hold it busy too; the system then refuses the eject and
  the alert shows, as Finder's "in use".
- **One eject at a time per volume.** While a volume's eject runs, its eject button is off, and
  another eject of it, from the menu or another window, does nothing. Once ejected, the volume
  stays so until a read of the mounts without it lands, so a read that still lists it can't
  turn the button back on for a volume that is gone; a volume mounted again at its mount point
  is a new one and can be ejected.
- **A refused eject.** An alert shows, as a sheet on the sidebar's window: "The disk “name”
  wasn’t ejected." with the system's reason under it, where Finder says "The disk “name”
  wasn’t ejected because one or more programs may be using it." The panes on the volume list
  their folders again at once and get new monitors, through the did-mount path
  (`VolumeEvents.ejectFailed`).
- **The whole disk only for its last browsable volume.** A volume on this machine that is the
  only browsable one mounted from its physical disk ejects the disk
  (`allPartitionsAndEjectDisk`), which detaches a disk image, as Finder's button does. A
  volume's whole disk comes from the device name the mount table gives (`/dev/disk5s2` is on
  `disk5`). Its physical disk comes from the I/O Registry, read in the same pass off the main
  thread: the whole disk of the first media above the whole disk with a BSD name, which for an
  APFS container's synthesized disk is its physical store (`disk3` is on `disk0s2`, so
  `disk0`); a disk with no media above it, as a plain partitioned disk or a disk image, is its
  own. So an HFS or ExFAT partition beside an APFS container counts as sharing the disk. A
  volume that shares its physical disk with another mounted volume is unmounted alone, and so
  is a share.
- **Toggle.** `Settings.showsLocationsInSidebar`, on by default, stored and discarded as
  0107's group toggles are, with View ▸ Show Locations in Sidebar between the other two.
- **Keys.** 0089's routing is unchanged: group rows can't be selected, so the arrows move from
  the favorites through the volumes to the workspaces, Return opens a volume, and a pane's
  chord still goes to the pane from a volume's row.

## Alternatives considered

- **Extend `MountTable` with the sidebar's details** — rejected: it places drops by path and
  must not wait on per-volume reads; both reuse `VolumeIdentity.mounted` and `VolumeEvents`.
- **Ask every volume, shares included, its name and kind** — rejected: one share that has
  stopped answering would hold every row.
- **Wait for the system's will-unmount before stopping loads** — rejected: it may come after
  the unmount has already found a folder open.
- **Run 0049's will-unmount before asking** — rejected: it fails the volume's file operations,
  which a refused eject would then have cost for nothing.
- **Always unmount only the clicked volume** — rejected: a disk image would stay attached and
  a disk wouldn't eject, unlike Finder's button.
- **Always eject the whole disk** — rejected: it unmounts the disk's other volumes without
  asking, where Finder asks first.
- **Ask, as Finder does, whether to eject the disk's other volumes too** — not done yet: the
  app would need the disk's volumes and a question of its own; unmounting the one volume loses
  nothing.

## Consequences

Ejecting a volume on a disk with other volumes mounted unmounts it alone, without Finder's
question; ejecting the last one then ejects the disk. Hidden volumes don't count: an external disk
with macOS installed may have its Preboot or VM volume mounted `MNT_DONTBROWSE`, which the
sidebar doesn't list, so ejecting its last listed volume ejects the disk and the hidden ones
go with it, as in Finder. A volume on this machine that stops answering holds the next read of
the list until it answers. A share mounted twice under one name shows the mount point's name,
"main 1", where Finder would show the server.
