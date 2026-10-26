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
- **Rows.** A symbol for a disk (`externaldrive`) or a share
  (`externaldrive.connected.to.line.below`), chosen with no read, the name, and Finder's eject
  button on each row that can be ejected (`canEject`: a share, a removable or ejectable disk,
  or one not on an internal bus). Every listed row can be ejected, as in Finder's default
  sidebar. A click or Return shows the volume's mount point in the window's focused pane
  (`Pane.navigate`), as a favorite folder's click does.
- **Eject.** The eject button and the row's context menu item, `Eject “name”` as Finder titles
  it, call `SidebarVolumes.eject`. It first calls `VolumeEvents.willUnmount` for the volume, so
  the app's own loads, size walks and file operations on it stop as at the system's
  will-unmount (0049), whose notification may come only once the unmount is under way. Then it
  runs the ejector on a `BlockingCallThread`: `FileManager.unmountVolume` with no system UI.
- **The whole disk only for its last volume.** A volume on this machine that is the only one
  mounted from its whole disk, browsable or not, ejects the disk (`allPartitionsAndEjectDisk`),
  which detaches a disk image, as Finder's button does. The whole disk comes from the device
  name the mount table already gives (`/dev/disk5s2` is on `disk5`), with no read. A volume
  that shares its disk with another mounted volume is unmounted alone, and so is a share. The
  row leaves when the system reports the
  unmount. A failure shows an alert, as a sheet on the sidebar's window: "The disk “name”
  wasn’t ejected." with the system's reason under it, where Finder says "The disk “name”
  wasn’t ejected because one or more programs may be using it." A pane whose load was stopped
  for an eject that then fails lists again on focus, as 0049 has it.
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
- **Always unmount only the clicked volume** — rejected: a disk image would stay attached and
  a disk wouldn't eject, unlike Finder's button.
- **Always eject the whole disk** — rejected: it unmounts the disk's other volumes without
  asking, where Finder asks first.
- **Ask, as Finder does, whether to eject the disk's other volumes too** — not done yet: the
  app would need the disk's volumes and a question of its own; unmounting the one volume loses
  nothing.

## Consequences

Ejecting a volume on a disk with other volumes mounted unmounts it alone, without Finder's
question; ejecting the last one then ejects the disk. An APFS volume is on its container's
synthesized disk, so a volume of another format on the same physical disk isn't seen as
sharing it: ejecting the last APFS volume ejects the physical disk, and unmounts that other
volume without asking. Telling them apart needs Disk Arbitration's disk tree. A volume on this machine that stops answering
holds the next read of the list until it answers. A share mounted twice under one name shows
the mount point's name, "main 1", where Finder would show the server.
