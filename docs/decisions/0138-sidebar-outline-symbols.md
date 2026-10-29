# 0138. Sidebar rows draw Finder's outline symbols, not the CoreTypes glyphs

- **Date:** 2026-10-29
- **Status:** accepted
- **Amends:** [0107](0107-sidebar-favorites.md) and [0108](0108-sidebar-locations.md) (where
  the row glyphs come from), [0114](0114-server-location.md) (the server row's glyph)

## Context

Dylan, 2026-10-29: "make sure we use the same icon style (not the gray filled in style) as
finder". `tmp/shots/fb-1029b-1.jpg` is Searcher's sidebar, `fb-1029b-2.jpg` Finder's, both at 2×;
`fb-1029-2.jpg` (Finder) and `fb-1029-3.jpg` (Searcher) show the same rows beside a list.

0107 and 0108 read Finder's glyphs from the `Sidebar*.icns` files in the system's CoreTypes
bundle. On macOS 26 those files still hold the old filled style: a grey-filled folder, a filled
house, a black filled circle for Downloads, a grey page. Finder no longer draws them. Its rows
are thin outline SF Symbols in the label color, which is how our rows already looked for the
moment before the files were read, when they showed their stand-in symbols.

## Decision

Every sidebar row draws an SF Symbol as a template image, except Applications. The mapping is
`SidebarIcons.Glyph.symbol`, the one place it is defined:

| Row | Symbol |
|---|---|
| Applications | `SidebarApplicationsFolder.icns`, read as before; `app.dashed` until read |
| Desktop | `dock.rectangle` |
| Documents | `doc` |
| Downloads | `arrow.down.circle` |
| Home | `house` |
| Any other folder | `folder` |
| Internal disk | `internaldrive` |
| External disk, disk image, card or disc on the internal bus | `externaldrive` |
| A share with no server row | `externaldrive.connected.to.line.below` |
| A server (0114) | `doc` |
| A file favorite | the type's icon from `TypeIconCache`, unchanged |

- **Applications.** Finder draws the ruler-pencil-brush "A" with a private symbol; the public
  set on this SDK has nothing like it (`appstore` is only in `CoreGlyphsPrivate`, and
  `NSImage(systemSymbolName:)` returns nil for it). The CoreTypes file for Applications is the
  same outline "A" Finder shows (the two shots match), so that one glyph is still read off the
  main thread by `CoreTypesIcons`, and swapped in when the read ends. If the file is missing or
  doesn't decode, the row keeps `app.dashed` and `SidebarIcons` logs a fault in the `sidebar`
  category. This replaces 0107's silent fallback.
- **No system lookup.** Neither AppKit nor Foundation exposes the symbol Finder's sidebar shows
  for a URL or a volume, so the names were picked by drawing the candidates beside the shots.
  Each exists on the macOS 26 SDK (`CoreGlyphs.bundle`'s `name_availability.plist`, all 2019 or
  2020 releases). `dock.rectangle` is Desktop's outline with the full-width bar at the bottom;
  `menubar.dock.rectangle` adds a bar at the top, which Finder's has not.
- **Size, weight and color are AppKit's.** A symbol takes the configuration the source list
  gives its image view for the row size, as the workspace rows and the eject glyph do: 11, 13 and
  15 points at medium weight for the small, medium and large sidebar icon size. At medium, a
  folder draws 16.5 points wide; Finder's measures 33 pixels, 16.5 points, in `fb-1029b-2.jpg`.
  The icon box stays 0107's 16, 18 and 24 points; a symbol's frame is that box widened by its
  alignment insets. The color is 0107's scheme, unchanged: the label color at rest, the accent on
  a selected row while the list doesn't have the keys, white on the emphasized selection, in
  light and dark.
- **Not added.** Finder's Network row and its Movies, Music and Pictures glyphs: the sidebar
  lists no Network row, and those folders aren't default favorites here. A removable disk keeps
  `externaldrive` as 0108's stand-in had it; Finder's choice for a card was not seen.

## Consequences

- The filled `Sidebar*.icns` files other than Applications' are no longer read.
- If a later macOS adds a public symbol for Applications, the CoreTypes read can go.
