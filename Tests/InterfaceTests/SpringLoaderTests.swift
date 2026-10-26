import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// `/r` holds the folders `docs` and `more`, the app `Tool.app`, a link `link` and a file
/// `a.txt`; `/r/docs` holds a folder `sub`.
private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [folder("docs"), folder("more"), package("Tool.app"), link("link"), file("a.txt")],
    "/r/more": [],
    "/r/docs": [folder("sub"), file("x.txt")],
    "/r/docs/sub": [file("one.txt")],
]

private func link(_ name: String) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: .symbolicLink, size: nil, modified: testDate, isHidden: false,
        isDataless: false)
}

private let delay: Duration = .milliseconds(500)

/// A pane at `/r` over the stub lister, in list or column view, shown by a view that is never
/// put in a window, with lists that take drops and spring on a clock the test advances. The
/// drag carries `/elsewhere/x.txt`.
@MainActor
private final class Fixture {
    let pane: Pane
    let clock = ManualClock()
    let loader: SpringLoader
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
    let info: StubDraggingInfo
    let mouse = Mouse()
    private let listController: ListingViewController?
    private let columnController: ColumnViewController?
    private let queue = FileOperationQueue(prompts: .unexpected) { _ in }
    private let mounts = MountTable(read: {
        [VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local)]
    })

    init(
        viewMode: ViewMode = .list, springDelay: @escaping @MainActor () -> Duration? = { delay }
    ) async {
        pane = Pane(
            location: Location(path: "/r"), service: ListingService(lister: StubLister(tree)),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
            viewMode: viewMode)
        loader = SpringLoader(
            delay: springDelay, clock: clock, isMouseDown: { [mouse] in mouse.isDown })
        info = StubDraggingInfo(pasteboard: pasteboard)
        if viewMode == .column {
            let controller = ColumnViewController(
                pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init())
            controller.startMonitor = { _ in }
            controller.fileOperations = queue
            controller.mountTable = mounts
            controller.springLoader = loader
            pane.onChange = { [weak controller] in controller?.paneDidChange() }
            controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            columnController = controller
            listController = nil
        } else {
            let controller = ListingViewController(
                pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
                tableView: ListingTableView())
            controller.fileOperations = queue
            controller.mountTable = mounts
            controller.springLoader = loader
            pane.onChange = { [weak controller] in controller?.paneDidChange() }
            controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
            listController = controller
            columnController = nil
        }
        drag("/elsewhere/x.txt")
        let mounts = mounts
        await settle {
            !self.lists.isEmpty && self.lists.allSatisfy { $0.pane.state.isLoaded }
                && mounts.isRead
        }
    }

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    /// The mouse button, down while the drag goes on.
    final class Mouse {
        var isDown = true
    }

    /// Puts the file at `path` on the drag's pasteboard, as Finder writes it.
    func drag(_ path: String) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(URL(fileURLWithPath: path).absoluteString, forType: .fileURL)
        #expect(pasteboard.writeObjects([item]))
    }

    /// The list, or each column left to right.
    var lists: [ListingViewController] {
        listController.map { [$0] } ?? columnController?.columnControllers ?? []
    }

    /// Moves the drag over the row `name` of the list at `index`, as AppKit asks the list to
    /// validate the drop there.
    @discardableResult
    func hover(over name: String, inList index: Int = 0) throws -> NSDragOperation {
        let list = lists[index]
        let row = try #require(list.pane.state.listing?.row(named: name))
        return list.tableView(
            list.tableView, validateDrop: info, proposedRow: row, proposedDropOperation: .on)
    }

    /// Advances the clock by `duration` once the wait it should end has started, then lets the
    /// main queue run what it woke.
    func advance(by duration: Duration) async {
        await settle { clock.waitingSleeps > 0 }
        clock.advance(by: duration)
        for _ in 0..<20 { await Task.yield() }
    }

    /// The column trail's folders, left to right.
    var columnFolders: [String] {
        pane.columnTrail?.columns.map(\.pane.location.path) ?? []
    }
}

@MainActor @Test func aFolderRowSpringsOpenInTheListAfterTheDelay() async throws {
    let fixture = await Fixture()

    try fixture.hover(over: "docs")
    await fixture.advance(by: delay - .milliseconds(1))

    #expect(fixture.pane.location.path == "/r")

    fixture.clock.advance(by: .milliseconds(1))
    await settle { fixture.pane.location.path == "/r/docs" }
}

@MainActor @Test func leavingTheRowBeforeTheDelayOpensNothing() async throws {
    let fixture = await Fixture()

    try fixture.hover(over: "docs")
    await settle { fixture.clock.waitingSleeps == 1 }
    try fixture.hover(over: "a.txt")

    #expect(fixture.loader.target == nil)
    await settle { fixture.clock.waitingSleeps == 0 }
    fixture.clock.advance(by: delay)
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.pane.location.path == "/r")
    #expect(fixture.info.resets == 2)
}

@MainActor @Test func movingToAnotherFolderRowStartsTheDelayAgain() async throws {
    let fixture = await Fixture()

    try fixture.hover(over: "docs")
    await fixture.advance(by: delay - .milliseconds(100))
    try fixture.hover(over: "more")
    await fixture.advance(by: delay - .milliseconds(1))

    #expect(fixture.pane.location.path == "/r")

    fixture.clock.advance(by: .milliseconds(1))
    await settle { fixture.pane.location.path == "/r/more" }
}

/// A folder dragged onto its own row can't drop into itself, so it doesn't spring either.
@MainActor @Test func aFolderDraggedOntoItsOwnRowDoesntSpring() async throws {
    let fixture = await Fixture()
    fixture.drag("/r/docs")

    #expect(try fixture.hover(over: "docs") == [])

    #expect(fixture.loader.target == nil)
    #expect(fixture.clock.waitingSleeps == 0)
}

@MainActor @Test func leavingTheListBeforeTheDelayOpensNothing() async throws {
    let fixture = await Fixture()
    let table = try #require(fixture.lists.first?.tableView)

    try fixture.hover(over: "docs")
    await settle { fixture.clock.waitingSleeps == 1 }
    table.draggingExited(fixture.info)

    #expect(fixture.loader.target == nil)
    await settle { fixture.clock.waitingSleeps == 0 }
    #expect(fixture.pane.location.path == "/r")
}

@MainActor @Test func spaceOverAFolderRowSpringsItAtOnce() async throws {
    let fixture = await Fixture()
    let table = try #require(fixture.lists.first?.tableView)

    try fixture.hover(over: "docs")
    #expect(table.springLoadingEntered(fixture.info) == [.enabled, .noHover])
    table.springLoadingActivated(true, draggingInfo: fixture.info)

    #expect(fixture.pane.location.path == "/r/docs")
    await settle { fixture.clock.waitingSleeps == 0 }
}

@MainActor @Test func packagesLinksAndFilesDontSpring() async throws {
    let fixture = await Fixture()
    let table = try #require(fixture.lists.first?.tableView)

    for name in ["Tool.app", "link", "a.txt"] {
        try fixture.hover(over: name)

        #expect(fixture.loader.target == nil, "\(name)")
        #expect(table.springLoadingUpdated(fixture.info) == [], "\(name)")
        table.springLoadingActivated(true, draggingInfo: fixture.info)
    }

    #expect(fixture.clock.waitingSleeps == 0)
    #expect(fixture.pane.location.path == "/r")
}

@MainActor @Test func nothingSpringsWhileTheSystemSettingIsOff() async throws {
    let folder = try TemporaryFolder("SpringLoaderTests")
    let defaults = temporarySuite(in: folder.url.path)
    defaults.set(false, forKey: Settings.springLoadingEnabledKey)
    let settings = Settings(defaults: defaults)
    let fixture = await Fixture(springDelay: { settings.springLoadingDelay })
    let table = try #require(fixture.lists.first?.tableView)

    // The drop still goes into the folder.
    #expect(try fixture.hover(over: "docs") == .move)
    #expect(table.springLoadingEntered(fixture.info) == [])
    table.springLoadingActivated(true, draggingInfo: fixture.info)
    for _ in 0..<20 { await Task.yield() }

    #expect(fixture.clock.waitingSleeps == 0)
    #expect(fixture.pane.location.path == "/r")
}

@MainActor @Test func aFolderRowInAColumnOpensItsColumnAfterTheDelay() async throws {
    let fixture = await Fixture(viewMode: .column)

    try fixture.hover(over: "docs", inList: 1)
    await fixture.advance(by: delay)

    await settle { fixture.columnFolders == ["/", "/r", "/r/docs"] }
    await settle { fixture.lists.count == 3 && fixture.lists[2].pane.state.isLoaded }

    // The drag goes on into the new column, whose folder rows spring too.
    try fixture.hover(over: "sub", inList: 2)
    await fixture.advance(by: delay)

    await settle { fixture.columnFolders == ["/", "/r", "/r/docs", "/r/docs/sub"] }
}

@MainActor @Test func theListGoesBackOnceTheDragEndsOverIt() async throws {
    let fixture = await Fixture()
    let table = try #require(fixture.lists.first?.tableView)
    fixture.pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    try fixture.hover(over: "docs")
    await fixture.advance(by: delay)
    await settle { fixture.pane.location.path == "/r/docs" }
    table.draggingEnded(fixture.info)

    #expect(fixture.pane.location.path == "/r")
    #expect(fixture.pane.selection.cursor == ExactName("a.txt"))
    #expect(!fixture.pane.canGoBack)
}

@MainActor @Test func theColumnsGoBackOnceTheDragEndsAwayFromThePane() async throws {
    let fixture = await Fixture(viewMode: .column)
    let table = fixture.lists[1].tableView

    try fixture.hover(over: "docs", inList: 1)
    await fixture.advance(by: delay)
    await settle { fixture.columnFolders == ["/", "/r", "/r/docs"] }
    table.draggingExited(fixture.info)
    await fixture.advance(by: SpringLoader.mouseCheckInterval)

    // The button is still down: the drag goes on elsewhere.
    #expect(fixture.columnFolders == ["/", "/r", "/r/docs"])

    fixture.mouse.isDown = false
    await fixture.advance(by: SpringLoader.mouseCheckInterval)

    await settle { fixture.columnFolders == ["/", "/r"] }
    #expect(fixture.pane.columnTrail?.columns[1].pane.selection.cursor == nil)
    // The mouse check stops with the drag.
    await settle { fixture.clock.waitingSleeps == 0 }
}

/// A drag that leaves the lists after a spring and comes back to end over one stops the mouse
/// check when it ends.
@MainActor @Test func aDragThatEndsOverAListStopsTheMouseCheck() async throws {
    let fixture = await Fixture()
    let table = try #require(fixture.lists.first?.tableView)

    try fixture.hover(over: "docs")
    await fixture.advance(by: delay)
    await settle { fixture.pane.location.path == "/r/docs" }
    table.draggingExited(fixture.info)
    await settle { fixture.clock.waitingSleeps == 1 }
    await settle { fixture.pane.state.isLoaded }
    try fixture.hover(over: "sub")
    await settle { fixture.clock.waitingSleeps == 2 }
    table.draggingEnded(fixture.info)

    #expect(fixture.pane.location.path == "/r")
    await settle { fixture.clock.waitingSleeps == 0 }
    fixture.mouse.isDown = false
    fixture.clock.advance(by: SpringLoader.mouseCheckInterval)
    for _ in 0..<20 { await Task.yield() }
    #expect(fixture.pane.location.path == "/r")
}
