import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing
import os

@testable import Browser
@testable import Interface

// A pane at a server shows its shares as volumes: the share icon, Kind "Volume", no size or
// date, and an Eject item in a share's context menu; with no share mounted it says the server
// isn't connected (docs/decisions/0114-server-location.md).

/// A pane at `testServer` whose mount table reads `mounts`, shown by a pane view controller,
/// once the pane shows the server's listing or that it isn't connected. Its share icon is read
/// by `readIcons`.
@MainActor
private struct Fixture {
    let pane: Pane
    let controller: PaneViewController
    var list: ListingViewController { controller.listingViewController }

    init(
        mounts: [VolumeIdentity] = [mountedShare("main"), mountedShare("music")],
        monitorsFolders: Bool = false,
        readIcons: @escaping @Sendable ([String]) async -> [String: Data] = { _ in [:] }
    ) async {
        pane = Pane(
            location: .server(testServer),
            service: ListingService(lister: StubLister([:]), mounts: StubMounts(mounts).table()),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
        controller = PaneViewController(
            pane: pane,
            iconCache: TypeIconCache(makeIcon: { _ in Self.typeIcon }, readIcons: readIcons),
            formatter: .init(), tableView: ListingTableView(), monitorsFolders: monitorsFolders)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        await settle {
            switch pane.state {
            case .loaded, .notConnected: true
            default: false
            }
        }
    }

    /// The icon every type shows, the volume's stand-in for the share icon among them.
    static let typeIcon = NSImage(size: NSSize(width: 16, height: 16))

    /// The cell of the column titled `title` in `row`.
    func cell(row: Int, column title: String) throws -> NSTableCellView {
        let table = list.tableView
        let column = try #require(table.tableColumns.first { $0.title == title })
        let view = list.tableView(table, viewFor: column, row: row)
        return try #require(view as? NSTableCellView)
    }
}

@MainActor @Test func aShareRowShowsVolumeForItsKindAndNoSizeOrDate() async throws {
    let fixture = await Fixture()

    for (row, name) in ["main", "music"].enumerated() {
        #expect(try fixture.cell(row: row, column: "Name").textField?.stringValue == name)
        #expect(try fixture.cell(row: row, column: "Kind").textField?.stringValue == "Volume")
        #expect(try fixture.cell(row: row, column: "Size").textField?.stringValue == "--")
        #expect(try fixture.cell(row: row, column: "Date Modified").textField?.stringValue == "--")
    }
}

@MainActor @Test func aShareRowShowsTheShareIconOnceReadAndTheVolumesUntilThen() async throws {
    let read = DispatchSemaphore(value: 0)
    let icon = NSImage(size: NSSize(width: 32, height: 32))
    icon.lockFocus()
    NSColor.red.drawSwatch(in: NSRect(x: 0, y: 0, width: 32, height: 32))
    icon.unlockFocus()
    let data = try #require(icon.tiffRepresentation)
    let asked = OSAllocatedUnfairLock(initialState: [String]())
    let fixture = await Fixture(readIcons: { names in
        asked.withLock { $0 += names }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                read.wait()
                continuation.resume()
            }
        }
        return [TypeIconCache.shareIconName: data]
    })

    #expect(try fixture.cell(row: 0, column: "Name").imageView?.image === Fixture.typeIcon)
    read.signal()
    await settle {
        (try? fixture.cell(row: 0, column: "Name").imageView?.image) !== Fixture.typeIcon
    }
    #expect(asked.withLock { $0 } == ["GenericSharepoint"])
    #expect(try fixture.cell(row: 0, column: "Name").imageView?.image?.size == icon.size)
}

@MainActor @Test func aServerWithNoShareSaysItIsntConnected() async {
    let fixture = await Fixture(mounts: [])

    #expect(fixture.pane.state.listing == nil)
    #expect(PaneViewController.message(for: fixture.pane) == "“HAL9000” isn't connected.")
}

@MainActor @Test func aServerPaneStartsNoFolderMonitor() async {
    let fixture = await Fixture(monitorsFolders: true)

    #expect(fixture.pane.monitor == nil)
    #expect(fixture.pane.state.listing?.count == 2)
}

@MainActor @Test func aShareRowsContextMenuEjectsTheShareAsTheSidebarDoes() async throws {
    let fixture = await Fixture()
    let stub = StubSidebarVolumes([
        SidebarVolume(mountPoint: "/Volumes/main", name: "main", kind: .network),
        SidebarVolume(mountPoint: "/Volumes/music", name: "music", kind: .network),
    ])
    let volumes = stub.list()
    await settle { volumes.volumes.count == 2 }
    fixture.list.volumes = volumes
    fixture.list.tableView.registry = try AppCommands.registry()

    let menu = fixture.list.contextMenu(forRow: 1)
    let eject = try #require(menu.items.last)
    #expect(eject.title == "Eject “music”")
    #expect(menu.items.dropLast().last?.isSeparatorItem == true)
    // Below the rows there is no share to eject.
    #expect(!fixture.list.contextMenu(forRow: -1).items.contains { $0.title.hasPrefix("Eject") })

    let action = try #require(eject.action)
    NSApp.sendAction(action, to: eject.target, from: eject)
    await settle { !stub.ejects.isEmpty }
    #expect(stub.ejects.map(\.mountPoint) == ["/Volumes/music"])
}

@MainActor @Test func aShareThatWontEjectSaysWhyAsTheSidebarDoes() async throws {
    let fixture = await Fixture()
    let stub = StubSidebarVolumes([
        SidebarVolume(mountPoint: "/Volumes/music", name: "music", kind: .network)
    ])
    stub.fail(with: "It's in use.")
    let volumes = stub.list()
    await settle { volumes.volumes.count == 1 }
    fixture.list.volumes = volumes
    fixture.list.tableView.registry = try AppCommands.registry()
    var alerts: [NSAlert] = []
    fixture.list.showAlert = { alerts.append($0) }

    let eject = try #require(fixture.list.contextMenu(forRow: 1).items.last)
    NSApp.sendAction(try #require(eject.action), to: eject.target, from: eject)
    await settle { !alerts.isEmpty }

    #expect(alerts.first?.messageText == "The disk “music” wasn’t ejected.")
    #expect(alerts.first?.informativeText == "It's in use.")
}

@MainActor @Test func aShareTheSidebarDoesntListHasNoEject() async throws {
    let fixture = await Fixture()
    let volumes = StubSidebarVolumes([]).list()
    fixture.list.volumes = volumes
    fixture.list.tableView.registry = try AppCommands.registry()

    #expect(!fixture.list.contextMenu(forRow: 1).items.contains { $0.title.hasPrefix("Eject") })
}

/// HAL9000's "main" is ejected and another server's "main" is mounted at /Volumes/main. Until
/// the server lists again, its row "main" is still shown, and it is no way into the other
/// server's share: it has no Eject and takes no drop (docs/decisions/0115-server-shares.md).
/// The checks run in an observer of the table's read, after the pane's, which has only started
/// the listing that drops the row.
@MainActor @Test func aRowWhoseMountPointAnotherServerNowHoldsRefusesEjectAndDrops() async throws {
    let settings = untouchedSettings()
    let root = VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)
    let mounts = StubMounts([root, mountedShare("main"), mountedShare("music")])
    let table = mounts.table()
    let pane = Pane(
        location: .server(testServer), service: ListingService(mounts: table),
        systemActions: StubSystemActions(), settings: settings, isFocused: true)
    // The sidebar's own read lists /Volumes/main as a disk it can eject, before and after.
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
        fileOperations: FileOperationQueue(prompts: .unexpected) { _ in }, mountTable: table,
        takePaneController: { _, pane in
            let made = PaneViewController(
                pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
                tableView: ListingTableView(), monitorsFolders: false)
            paneController = made
            return made
        })
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()
    let list = try #require(paneController).listingViewController
    list.tableView.registry = try AppCommands.registry()
    await settle { pane.state.isLoaded }
    let pasteboard = testPasteboard()
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString(URL(fileURLWithPath: "/Users/someone/a.txt").absoluteString, forType: .fileURL)
    #expect(pasteboard.writeObjects([item]))
    let info = StubDraggingInfo(pasteboard: pasteboard, mask: [.copy, .move, .generic, .link])
    func mainRow() throws -> Int { try #require(pane.state.listing?.row(named: "main")) }
    func ejects(row: Int) -> Bool {
        list.contextMenu(forRow: row).items.contains { $0.title == "Eject “main”" }
    }
    func validate(row: Int) -> NSDragOperation {
        list.tableView(
            list.tableView, validateDrop: info, proposedRow: row, proposedDropOperation: .on)
    }
    #expect(ejects(row: try mainRow()))
    #expect(validate(row: try mainRow()) == .copy)

    var shown: (row: Int?, ejects: Bool, drop: NSDragOperation)?
    let observer = NSObject()
    table.observe(for: observer) {
        guard let row = pane.state.listing?.row(named: "main") else {
            shown = (nil, false, [])
            return
        }
        shown = (row, ejects(row: row), validate(row: row))
    }
    mounts.set([root, mountedShare("main", of: "192.168.1.5"), mountedShare("music")])
    table.refresh()
    await settle { shown != nil }

    let after = try #require(shown)
    #expect(after.row != nil)
    #expect(!after.ejects)
    #expect(after.drop == [])
    withExtendedLifetime(observer) {}
}

// A window at a server reads the share icon through the shared cache and its default reader. That
// reader, named by a default argument, once aborted the process ("freed pointer was not the last
// allocation") when called for rows AppKit made.
@MainActor @Test func aWindowAtAServerReadsTheShareIconFromTheSystem() async throws {
    let settings = untouchedSettings()
    let mounts = StubMounts([mountedShare("main"), mountedShare("music")]).table()
    let controller = BrowserWindowController(
        location: Location(path: "/root"), service: ListingService(mounts: mounts),
        systemActions: StubSystemActions(), settings: settings,
        favorites: Favorites(settings: settings), volumes: StubSidebarVolumes().list())
    let window = try #require(controller.window)
    window.contentView?.layoutSubtreeIfNeeded()
    let pane = controller.workspace.selectedTab.focusedPane
    pane.navigate(to: .server(testServer))
    await settle { pane.state.isLoaded }
    window.contentView?.layoutSubtreeIfNeeded()
    let cache = TypeIconCache.shared
    await settle { cache.shareIcon {} !== cache.icon(for: .volume) }
}
