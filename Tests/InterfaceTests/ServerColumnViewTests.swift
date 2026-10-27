import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// Column view and the path bar of a folder in a server's share: the server's column first,
// selecting as Finder's first column does, its share rows ejecting as the list's do, and the
// bar starting at the server (docs/decisions/0114-server-location.md).

/// HAL9000's shares `main` and `music`, mounted in /Volumes; `music` holds a folder `a`.
private let shares: [String: [DirectoryEntry]] = [
    "/": [folder("Volumes")],
    "/Volumes": [folder("main"), folder("music")],
    "/Volumes/main": [file("n.txt")],
    "/Volumes/music": [folder("a"), file("m.txt")],
    "/Volumes/music/a": [file("x.txt")],
]

/// A focused pane at `location` in `viewMode`, listed from `table`, shown by a pane view
/// controller that starts folder monitors if `monitorsFolders`.
@MainActor
private func paneController(
    at location: Location, viewMode: ViewMode, table: MountTable, monitorsFolders: Bool = false
) -> PaneViewController {
    let pane = Pane(
        location: location,
        service: ListingService(lister: StubLister(shares), mounts: table),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: viewMode)
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: monitorsFolders)
    controller.view.frame = NSRect(x: 0, y: 0, width: 1000, height: 400)
    return controller
}

/// A table of HAL9000's two shares, read.
@MainActor
private func readTable() async -> MountTable {
    let table = StubMounts([mountedShare("main"), mountedShare("music")]).table()
    await table.firstRead()
    return table
}

/// Whether every column of `controller`'s pane, or its list, shows its listing.
@MainActor
private func listed(_ controller: PaneViewController) -> Bool {
    guard let trail = controller.pane.columnTrail else { return controller.pane.state.isLoaded }
    return trail.columns.allSatisfy { $0.pane.state.isLoaded }
}

@MainActor @Test func aShareFoldersPathBarStartsAtTheServer() async throws {
    let table = await readTable()
    let controller = paneController(
        at: Location(path: "/Volumes/music/a"), viewMode: .list, table: table)
    await settle { listed(controller) }

    #expect(controller.pathBar.segments.map(\.title) == ["HAL9000", "music", "a"])
    #expect(controller.pathBar.segments[0].accessibilityTitle() == "HAL9000")

    controller.pathBar.segments[0].performClick(nil)

    #expect(controller.pane.location == .server(testServer))
    await settle { listed(controller) }
    #expect(controller.pathBar.segments.map(\.title) == ["HAL9000"])
    #expect(controller.pane.selection.cursor == ExactName("music"))
}

/// A disk keeps the bar from `/` (0026-path-bar.md).
@MainActor @Test func aDiskFoldersPathBarStartsAtTheStartupDisk() async throws {
    let backup = VolumeIdentity(device: "/dev/disk5s1", mountPoint: "/Volumes/main", kind: .local)
    let table = StubMounts([backup]).table()
    await table.firstRead()
    let controller = paneController(
        at: Location(path: "/Volumes/main"), viewMode: .list, table: table)
    await settle { listed(controller) }

    #expect(controller.pathBar.segments.map(\.title).dropFirst() == ["Volumes", "main"])
}

/// The first column selects across its whole width, as Finder's does: the server's once the
/// table's read adds it, and the share's column draws the rounded band from then on.
@MainActor @Test func theServerColumnIsTheOneWithTheFullWidthSelection() async throws {
    let table = StubMounts([mountedShare("main"), mountedShare("music")]).table()
    let controller = paneController(
        at: Location(path: "/Volumes/music/a"), viewMode: .column, table: table)
    let columns = controller.columnViewController
    #expect(columns.columnControllers.map(\.pane.location.name) == ["music", "a"])
    #expect(columns.columnControllers[0].tableView.selectionShape == .fullWidth)

    await table.firstRead()
    await settle { listed(controller) }

    #expect(columns.columnControllers.map(\.pane.location.name) == ["HAL9000", "music", "a"])
    #expect(
        columns.columnControllers.map(\.tableView.selectionShape) == [
            .fullWidth, .roundedBand, .roundedBand,
        ])
    #expect(controller.pathBar.segments.map(\.title) == ["HAL9000", "music", "a"])
}

/// The server's column has no folder to watch, so it starts no monitor; it lists again on the
/// mount table's changes.
@MainActor @Test func theServersColumnStartsNoFolderMonitor() async throws {
    let table = await readTable()
    let controller = paneController(
        at: .server(testServer), viewMode: .column, table: table, monitorsFolders: true)
    await settle { listed(controller) }

    let columns = controller.columnViewController.columnControllers
    #expect(columns.map(\.pane.location) == [.server(testServer)])
    #expect(columns[0].pane.monitor == nil)
}

/// A share row in the server's column offers Eject, as in the list, through the sidebar's
/// volumes the window hands the pane.
@MainActor @Test func aShareRowInTheServersColumnOffersEject() async throws {
    let settings = untouchedSettings()
    let table = await readTable()
    let pane = Pane(
        location: .server(testServer),
        service: ListingService(lister: StubLister(shares), mounts: table),
        systemActions: StubSystemActions(), settings: settings, isFocused: true,
        viewMode: .column)
    let stub = StubSidebarVolumes([
        SidebarVolume(mountPoint: "/Volumes/main", name: "main", kind: .network),
        SidebarVolume(mountPoint: "/Volumes/music", name: "music", kind: .network),
    ])
    let volumes = stub.list()
    await settle { volumes.volumes.count == 2 }
    var paneController: PaneViewController?
    let controller = BrowserWindowController(
        workspace: Workspace(tab: Tab(pane: pane)), workspaces: WorkspaceList(),
        favorites: Favorites(settings: settings), volumes: volumes, settings: settings,
        takePaneController: { _, pane in
            let made = PaneViewController(
                pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
                tableView: ListingTableView(), monitorsFolders: false)
            paneController = made
            return made
        })
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()
    let columns = try #require(paneController).columnViewController
    await settle { columns.columnControllers.first?.pane.state.isLoaded == true }

    let menu = try #require(columns.columnControllers.first).contextMenu(forRow: 1)

    #expect(menu.items.last?.title == "Eject “music”")
}
