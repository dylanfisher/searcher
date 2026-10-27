# 0118. A volume's row in a list or a column has the sidebar's eject button

- **Date:** 2026-10-27
- **Status:** accepted
- **Builds on:** [0108](0108-sidebar-locations.md) (the sidebar's eject button and the eject
  path), [0115](0115-server-shares.md) (a server's mounted and unmounted shares)

## Context

Dylan, 2026-10-27: "volumes should have the eject button in column and list view like finder
does". His screenshots of Finder's Computer view show, in column view, Finder's filled eject
glyph left of the folder chevron on every mounted share's row, and none on Macintosh HD or
Network; in list view the glyph sits at the right end of the Name column, before Date Modified,
on the same rows. In a server's column (`tmp/shots/finder-server-unmounted-shares.jpg`) only the
mounted share, music, has it. Measured on that 2x screenshot, the glyph is 10 points wide and
ends 6 points before the chevron.

Until now only the context menu of a server's share row had Eject (0114), and only the
sidebar had the button.

## Decision

- **Which rows.** A row shows the button when its item is a volume the sidebar lists as one it
  can eject (`SidebarVolume.canEject`): at a server, a share the mount table has where the row
  says (`Pane.childLocation(of:)`); in a folder, a volume mounted at the row's path, as in
  /Volumes. An unmounted share, the startup disk's link and an internal disk have none. The
  sidebar's volumes are the one list of what can be ejected, so the rows follow them: the button
  comes and goes with each change of the list, in every window. The context menu's Eject now
  covers the same rows, so the menu and the button agree.
- **One eject path.** The button and the menu call `SidebarVolumes.eject`, as the sidebar's do,
  with its `VolumeEvents.willEject`, its one eject at a time per volume and its alert when the
  system refuses. While a volume's eject runs, and until a read without it lands, its button is
  off (`SidebarVolumes.ejecting`), as the sidebar's is.
- **The same button.** It is the sidebar's (`WorkspaceSidebarViewController.Cell.makeEjectButton`):
  `eject.fill`, a `HoverButton` with the `.glyph` look and its tints, at the sidebar's scale
  (`Cell.ejectScale`) of a symbol at the name's font size, 13 points, which is what the
  sidebar's medium rows draw. On an emphasized selection it takes the selected row's text color,
  as the chevron and the name do; the Name cell (`ListingNameCellView`) passes the row's
  background style to it.
- **Where.** The button ends where the chevron's view starts in a column, and at the cell's
  trailing edge in a list (`ListingCellLayout.ejectX`). The glyph is centered in the 22-point
  button, so it ends about 6 points before the chevron, as Finder's does. The name ends where the
  button starts and truncates before it, never under it. The rename field ends there too.
- **VoiceOver names the volume.** A list can show many buttons, so each one's label is
  `Eject “name”`, the menu item's title (`WorkspaceSidebarViewController.ejectTitle`), not the
  glyph's "Eject" alone.
- **A press goes to the button.** The table never sees it, so the selection, the keys and the
  folder shown stay as they were.
- **Cost per row.** The button is made the first time a cell shows one, so the cells of other
  rows carry no view, tracking area or constraint for it. At each change of the sidebar's
  volumes the list builds a dictionary of the ejectable volumes by mount point and a set of the
  folders that hold them. A row of a folder not in that set costs one set lookup; a row of
  /Volumes builds its path and looks it up once. Volumes change rarely and rows are configured
  as they scroll in, so the build runs at the change and the lookup per row.

## Alternatives considered

- **A linear search of the sidebar's volumes per row**, as the menu's Eject did — rejected: it
  ran once per right-click, but the button is configured for each row that scrolls in.
- **Read whether a row is a mount point from its entry** — rejected: it needs a stat of each
  row, and the sidebar's list already says which volumes can be ejected.
- **A second eject glyph sized for the list** — rejected: one glyph, scale and set of tints,
  defined once for the sidebar.

## Consequences

A double-click on a column's grip fits the column to its longest name without room for the
button, so a volume's long name in a fitted column truncates before the glyph. A volume mounted
outside /Volumes shows the button in its parent folder's listing too, wherever that is.
