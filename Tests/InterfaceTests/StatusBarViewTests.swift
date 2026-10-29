import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// A free-space read for tests: records each call and the thread it ran on, and holds it while
/// `holds` until `release`, then returns `bytes`.
private final class HeldRead: @unchecked Sendable {
    private let condition = NSCondition()
    private let bytes: Int64
    private var holds: Bool
    private var callThreads: [Bool] = []

    init(bytes: Int64, holds: Bool = false) {
        self.bytes = bytes
        self.holds = holds
    }

    var calls: Int { condition.withLock { callThreads.count } }
    /// Whether every read ran on a `BlockingCallThread`, off the main thread.
    var ranOffMain: Bool { condition.withLock { callThreads.allSatisfy { $0 } } }

    func release() {
        condition.withLock {
            holds = false
            condition.broadcast()
        }
    }

    func read(_ path: String) throws -> Int64? {
        condition.lock()
        defer { condition.unlock() }
        callThreads.append(BlockingCallThread.isCurrent && !Thread.isMainThread)
        while holds { condition.wait() }
        return bytes
    }
}

/// A browser window at `/root` that is never shown, with its first pane loaded and its table
/// first responder, and its free space read by `read`.
@MainActor
private struct Fixture {
    let controller: BrowserWindowController
    let window: NSWindow
    let read: HeldRead

    init(
        settings: Settings = untouchedSettings(), folders: [String: [DirectoryEntry]] = folders,
        read: HeldRead = HeldRead(bytes: 789_740_000_000),
        volume: VolumeIdentity = ListingService.listerVolume
    ) async throws {
        self.read = read
        controller = BrowserWindowController(
            location: Location(path: "/root"),
            service: ListingService(
                lister: StubLister(folders), rootVolumeName: { "Test Disk" },
                volumeOf: { _ in volume }),
            systemActions: StubSystemActions(), settings: settings,
            favorites: Favorites(settings: settings), volumes: StubSidebarVolumes().list(),
            freeSpace: FreeSpace(read: read.read))
        window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let workspace = controller.workspace
        await settle { workspace.selectedTab.focusedPane.state.isLoaded }
    }

    static let folders = [
        "/root": [folder("docs"), file("a.txt"), file("b.txt"), file(".hidden"), folder("empty")],
        "/root/docs": [file("inside.txt")],
        "/root/empty": [],
        "/": [folder("root")],
    ]

    var tab: Tab { controller.workspace.selectedTab }
    var text: String { controller.statusBar.text }

    var keyTable: ListingTableView {
        get throws { try #require(window.firstResponder as? ListingTableView) }
    }

    /// Waits until the bar says `expected`; fails the test on the caller's line if it never
    /// does.
    func waitForText(_ expected: String, line: Int = #line) async {
        await settle(line: line) { controller.statusBar.text == expected }
    }

    /// `view`'s frame in the window.
    func frame(of view: NSView) -> NSRect {
        view.convert(view.bounds, to: nil)
    }
}

/// The item that runs command `id`, anywhere in `menu`.
@MainActor
private func menuItem(_ id: CommandID, in menu: NSMenu) -> NSMenuItem? {
    for item in menu.items {
        if item.representedObject as? CommandID == id { return item }
        if let found = item.submenu.flatMap({ menuItem(id, in: $0) }) { return found }
    }
    return nil
}

private let available = ", 789.74 GB available"

/// The bar counts the rows the list shows, hidden files only while they show, and the
/// selection, as Finder's status bar does.
@MainActor @Test func theBarCountsTheRowsAndTheSelectionTheListShows() async throws {
    let fixture = try await Fixture()
    let pane = fixture.tab.focusedPane
    await fixture.waitForText("4 items" + available)

    pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    #expect(fixture.text == "1 of 4 selected" + available)

    pane.select(
        Selection([ExactName("a.txt"), ExactName("b.txt")], cursor: ExactName("b.txt")))
    #expect(fixture.text == "2 of 4 selected" + available)

    pane.select(Selection())
    pane.settings.showHidden = true
    await fixture.waitForText("5 items" + available)

    pane.settings.showHidden = false
    await fixture.waitForText("4 items" + available)

    pane.navigate(to: Location(path: "/root/docs"))
    await fixture.waitForText("1 item" + available)

    pane.navigate(to: Location(path: "/root/empty"))
    await fixture.waitForText("0 items" + available)
}

/// In column view the bar counts the folder the window is titled after: the folder selected in
/// the focused column, once its column lists, else the focused column's own, with its selection.
@MainActor @Test func inColumnViewTheBarCountsTheFolderTheTitleNames() async throws {
    let fixture = try await Fixture()
    try fixture.keyTable.keyDown(with: try keyEvent("3", modifiers: .command))
    let pane = fixture.tab.focusedPane
    await settle { pane.commandPane !== pane && pane.commandPane.state.isLoaded }
    let trail = try #require(pane.columnTrail)
    let rootColumn = pane.commandPane
    await fixture.waitForText("4 items" + available)

    rootColumn.select(Selection([ExactName("docs")], cursor: ExactName("docs")))

    #expect(fixture.window.title == "docs")
    await settle { trail.selectedFolderColumn?.state.isLoaded == true }
    await fixture.waitForText("1 item" + available)

    rootColumn.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    #expect(fixture.window.title == "root")
    #expect(fixture.text == "1 of 4 selected" + available)

    rootColumn.select(Selection([ExactName("empty")], cursor: ExactName("empty")))

    await settle { trail.selectedFolderColumn?.state.isLoaded == true }
    await fixture.waitForText("0 items" + available)
}

/// With two panes the bar is the focused pane's, and follows the focus.
@MainActor @Test func theBarFollowsTheFocusedPane() async throws {
    let fixture = try await Fixture()
    let left = fixture.tab.layout.focused
    try fixture.keyTable.keyDown(with: try keyEvent("T", modifiers: [.command, .shift]))
    let right = fixture.tab.layout.focused
    #expect(right != left)
    let rightPane = try #require(fixture.tab.panes[right])
    rightPane.navigate(to: Location(path: "/root/docs"))
    await fixture.waitForText("1 item" + available)

    let leftView = try #require(fixture.controller.paneViewController(for: left))
    #expect(fixture.window.makeFirstResponder(leftView.keyView))

    #expect(fixture.text == "4 items" + available)
}

/// Cmd-/ hides the bar and writes the setting to the config file, and the panes take its
/// place; Cmd-/ again shows it. The menu item says which it would do.
@MainActor @Test func cmdSlashTogglesTheBarThroughTheConfig() async throws {
    let config = try await ConfigFixture("StatusBarViewTests")
    let fixture = try await Fixture(settings: config.settings)
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let item = try #require(menuItem(ViewCommands.toggleStatusBar.id, in: menu))
    let bar = fixture.controller.statusBar
    let paneView = fixture.controller.paneViewController.view
    #expect(fixture.controller.validateMenuItem(item))
    #expect(item.title == "Hide Status Bar")
    #expect(fixture.frame(of: bar).minY == 0)
    #expect(fixture.frame(of: paneView).minY == StatusBarView.height)
    let slash = try keyEvent("/", modifiers: .command, keyCode: 44)

    try fixture.keyTable.keyDown(with: slash)
    fixture.window.contentView?.layoutSubtreeIfNeeded()

    #expect(!config.settings.showsStatusBar)
    #expect(fixture.frame(of: paneView).minY == 0)
    #expect(fixture.frame(of: bar).maxY <= 0)
    #expect(fixture.controller.validateMenuItem(item))
    #expect(item.title == "Show Status Bar")
    await config.settings.flushConfigBounded()
    let text = try String(contentsOf: config.file, encoding: .utf8)
    #expect(configLoad(text).values[.showsStatusBar] == .bool(false))

    try fixture.keyTable.keyDown(with: slash)
    fixture.window.contentView?.layoutSubtreeIfNeeded()

    #expect(config.settings.showsStatusBar)
    #expect(fixture.frame(of: bar).minY == 0)
    #expect(fixture.frame(of: paneView).minY == StatusBarView.height)
    await fixture.waitForText("4 items" + available)
}

/// The space shows once its read lands. A share that doesn't answer never holds the bar: the
/// count shows at once, the read runs off the main thread, and the space joins it when the
/// read returns.
@MainActor @Test func theSpaceShowsOnceKnownAndAShareThatDoesntAnswerNeverBlocks() async throws {
    let read = HeldRead(bytes: 7_000_000_000, holds: true)
    let share = VolumeIdentity(
        device: "//me@nas/share", mountPoint: "/Volumes/share", kind: .network)
    let fixture = try await Fixture(read: read, volume: share)

    #expect(fixture.text == "4 items")
    await settle { read.calls == 1 }
    fixture.tab.focusedPane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    #expect(fixture.text == "1 of 4 selected")
    #expect(read.calls == 1)

    read.release()

    await fixture.waitForText("1 of 4 selected, 7 GB available")
    #expect(read.ranOffMain)
}

/// The bar sits along the window's bottom edge under the panes, so the list's last row and
/// the path bar stay above it, scrolled to the end.
@MainActor @Test func theLastRowAndThePathBarStayAboveTheBar() async throws {
    let names = (0..<80).map { file(String(format: "f%02d.txt", $0)) }
    let fixture = try await Fixture(folders: ["/root": names, "/": [folder("root")]])
    let table = try fixture.keyTable
    let paneController = fixture.controller.paneViewController
    let bar = fixture.frame(of: fixture.controller.statusBar)
    #expect(bar.minY == 0)
    #expect(bar.width == fixture.frame(of: paneController.view).width)

    table.scrollRowToVisible(names.count - 1)
    fixture.window.contentView?.layoutSubtreeIfNeeded()

    let lastRow = table.convert(table.rect(ofRow: names.count - 1), to: nil)
    let visible = table.convert(table.visibleRect, to: nil)
    #expect(visible.contains(lastRow))
    #expect(lastRow.minY >= bar.maxY)
    #expect(fixture.frame(of: paneController.pathBar).minY >= bar.maxY)
}
