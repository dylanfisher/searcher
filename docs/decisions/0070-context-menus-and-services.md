# 0070. Context menus, Services and the Commander F-key preset

- **Date:** 2026-10-23
- **Status:** accepted

## Context

M4.10 asks for a context menu on rows built from `CommandID` lists, a Services menu fed by the
selection, and the Commander F-key preset in `tmp/behavior.md` behind a setting that is off by
default. File and Edit already listed every file and clipboard command
([0060](0060-menu-items-for-every-command.md), [0066](0066-file-commands.md),
[0069](0069-cut-and-paste.md)), so the main menu gains only Services. The plan doesn't say what a
right-click below the rows shows, which pane the menu acts on, how the services reach the menu,
or how a setting changes the keys of a registry that was built once.

## Decision

- **One builder.** `ContextMenuBuilder` builds every context menu from a list of `CommandID`s and
  separators. Titles come from the registry, and so does the key equivalent: the first chord, left
  off for a key without Command, Control or Option (Return, Space), as the main menu does. A
  listed command the registry lacks fails the build, naming it. Each item targets the clicked
  table, which runs the command and turns the item off while it would do nothing, as for the main
  menu.
- **Row menu:** Open, Open in New Tab, Open in Other Pane; Quick Look; Rename, Duplicate, Copy
  and Move to Other Pane; Cut, Copy, Copy Path; Reveal in Finder; Move to Trash. A right-click on
  a row outside the selection selects that row first, as Finder does; on a selected row it keeps
  the selection.
- **Folder menu,** for a right-click below the rows: New Folder; Paste, Move Items Here; Open
  Terminal Here. The selection stays.
- **The clicked pane takes the keys.** `ListingTableView.menu(for:)` makes the table first
  responder before building the menu, as a left click would, so the window focuses its pane (or
  column) and the commands' context, other pane included, is that pane's.
- **Services.** `ListingViewController` is the `NSServicesMenuRequestor`: it offers the selection
  for `public.file-url`, the older `NSFilenamesPboardType` (which the pasteboard reads from the
  file URLs) and plain text, with no return type, and writes it through
  `PasteboardFileClipboard` with `ClipboardCommands.selectedURLs`, the shape and URLs Copy writes.
  `validRequestor` checks only that something is selected; the URLs are built when a service
  runs. The app menu has a Services submenu, which `MainMenuBuilder.install` makes the app's
  services menu, and `install` registers the send types. The builder adds no Services item to the
  context menus: AppKit appends the services for the selection to a context menu that a view
  returns from `menu(for:)`, from the same requestor.
- **F-keys.** `KeyChord.Key.function(n)` names F1 to F35; Fn is not part of a chord, so F5 and
  Fn-F5 are one chord. `FileCommands.commanderFKeys` maps Copy and Move to Other Pane, New Folder
  and Move to Trash to F5 to F8. `AppCommands.registry(commanderFKeys:)` adds each F-key after the
  command's own chords, so the menus still show Cmd-Shift-C and the rest, and F5 and F6 run the
  same commands, which ask first. `PaneViewController` keeps the two registries and gives each
  table the one the setting asks for, again after every settings change.
- **Setting.** `Settings.commanderFKeys`, off by default. When the Settings window gets a
  checkbox for it, its help says F-keys need Fn unless the system's standard function keys
  setting is on. Until then it is set with
  `defaults write com.dylanfisher.searcher commanderFKeys -bool true`.

## Alternatives considered

- **A Services submenu built into each context menu** — rejected: AppKit gives no way to fill a
  second services menu, and it already adds the services to context menus.
- **A menu set once on the table (`NSView.menu`)** — rejected: it would show the same menu for
  every click and couldn't select the clicked row first.
- **Leave the clicked pane unfocused** — rejected: Copy to Other Pane in the menu would copy from
  the focused pane, not the one clicked.
- **Separate commands for F5 to F8** — rejected: two commands per action, two menu items or a
  test exception, and a confirm path to keep in step.
- **Rebuild the registry per key press** — rejected: two registries made once cost nothing per
  key.

## Consequences

Any later context menu (the path bar, the tab strip) goes through `ContextMenuBuilder`. The
services AppKit adds depend on what the user has installed and turned on in System Settings, so no
test can list them; the requestor is tested instead. A drag's pasteboard and a service's use the
same writer, so a change to Copy's pasteboard shape changes all three.

## Amendment: symbols, Share… and Quick Actions (M4.16)

- **Symbols.** `ContextMenuBuilder.symbols` gives an SF Symbol to each command whose Finder
  item of the same name shows one on macOS 26: Open, Quick Look, Rename, Duplicate, Cut, Copy,
  Paste, Move to Trash, New Folder, and Open Terminal Here, after Finder's New Terminal at
  Folder service. Names are the ones that exist on macOS 14 (`doc.on.doc` is
  `document.on.document` under its older name). A name with no symbol fails the build of the
  menu. Commands Finder has no item for (Open in Other Pane, Copy Path, Reveal in Finder and
  the rest) show none. The main menu's items get none.
- **Share…** follows Copy Path in the row menu: `NSSharingServicePicker.standardShareMenuItem`
  over the selection's file URLs, which `ListingViewController` passes to the builder when the
  menu is built, after the clicked row is selected. AppKit fills its submenu with the share
  extensions the user has turned on, and adds its icon.
- **Quick Actions: not built; no public API lists them.** Finder's Quick Actions submenu comes
  from three sources, and none has a public way for another app to list them or run them on a
  selection:
  - Action extensions that opt into Finder (`com.apple.ui-services` with
    `NSExtensionServiceAllowsFinderPreviewItem`, such as Markup). Hosting them needs
    `NSExtension`, which is SPI on macOS. ExtensionFoundation's `AppExtensionPoint` and
    `AppExtensionIdentity` find only ExtensionKit extensions of points the host app declares.
  - Automator Quick Action workflows in `~/Library/Services`. They are Services, but the ones
    Automator saves for Finder carry `NSRequiredContext` `NSApplicationIdentifier` =
    `com.apple.finder`, so AppKit offers them to Finder only. Listing them means parsing the
    workflow bundles' private format, and running one outside Finder means `NSPerformService`
    against that context.
  - Shortcuts marked "Use as Quick Action". Shortcuts offers no API to list them; those also
    marked for the Services menu already show in Services.

  Services that take files and aren't limited to Finder already show in the context menu
  (above). A Quick Actions submenu waits for a public API.

## Amendment: the preset is a default alternate (2026-10-26)

`AppCommands.registry(commanderFKeys:)` and `PaneViewController`'s two registries are gone.
While the setting is on, each F-key is its command's default alternate, which none of the four
has otherwise; the user's own alternate replaces it, and removing it is stored
([0106](0106-primary-and-alternate-shortcuts.md)). `PaneViewController.registry(for:)` makes
the registry again only when the setting or the shortcuts change, not per key.

## Amendment: tag dots (2026-10-27, TG.1)

The row menu has Finder's tag dots after Share…, an item with a view of its own
(`ContextMenuBuilder.Item.tags`), and the File menu ends with a Tags submenu
([0121](0121-tag-commands.md)).

## Amendment: a right-click on a name (2026-10-27, TG.2)

The Name cell takes a right-click or a Control-click on its label or icon and passes it on to
the table, which builds the menu; before, those views took the press and no menu opened
([0124](0124-tags-in-rows-and-preview.md)).
