import AppKit
import Base
import Browser
import Foundation
import TestSupport
import Testing

@testable import Interface

@MainActor
final class StubSystemActions: SystemActions {
    private(set) var openedFiles: [URL] = []
    private(set) var openedURLs: [URL] = []
    private(set) var copiedTexts: [String] = []
    private(set) var revealed: [[URL]] = []
    private(set) var openedInApp: [(folder: URL, bundleID: String)] = []

    func openFile(_ url: URL) { openedFiles.append(url) }
    func openURL(_ url: URL) { openedURLs.append(url) }
    func copyToPasteboard(_ text: String) { copiedTexts.append(text) }
    func revealInFinder(_ urls: [URL]) { revealed.append(urls) }
    func open(_ folder: URL, inAppWithBundleID bundleID: String) {
        openedInApp.append((folder, bundleID))
    }
}

extension ListingState {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
}

/// The name in each row the table shows, read from the listing it was given.
@MainActor
func rowNames(_ table: NSTableView) -> [String] {
    guard let controller = table.dataSource as? ListingViewController else { return [] }
    return (0..<table.numberOfRows).map { controller.listing?[$0].name ?? "" }
}

/// A table that reports `clickedRow` as a double-click on that row would, since a test can't send
/// a real click through the table's mouse tracking.
final class ClickedRowTableView: ListingTableView {
    var row = -1

    override var clickedRow: Int { row }
}

/// A pane at `/root` holding a folder `docs` and files `a.txt` and `b.txt`, in a view controller
/// that is never shown.
@MainActor
private struct Fixture {
    let pane: Pane
    let actions = StubSystemActions()
    let controller: PaneViewController
    let table: ClickedRowTableView

    init(
        lister: any Lister = StubLister(Fixture.folders), monitors: Bool = false,
        rootVolumeName: @escaping @Sendable () -> String = { "Test Disk" }
    ) {
        pane = Pane(
            location: Location(path: "/root"),
            service: ListingService(lister: lister, rootVolumeName: rootVolumeName),
            systemActions: actions, settings: untouchedSettings(), isFocused: true)
        table = ClickedRowTableView()
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: table, monitorsFolders: monitors)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    }

    static let folders = [
        "/root": [folder("docs"), file("a.txt"), file("b.txt")],
        "/root/docs": [file("inside.txt")],
        "/": [folder("root")],
    ]
}

@MainActor @Test func showsASpinnerWhileLoadingAndTheTableWhenLoaded() async throws {
    let lister = GatedLister(Fixture.folders.mapValues { .batches([$0]) })
    let fixture = Fixture(lister: lister)

    #expect(!fixture.controller.spinner.isHidden)
    #expect(fixture.controller.spinner.accessibilityLabel() == "Loading root")

    lister.releaseAll()
    await settle { fixture.pane.state.isLoaded }

    #expect(fixture.controller.spinner.isHidden)
    #expect(fixture.controller.listingViewController.view.isHidden == false)
    #expect(rowNames(fixture.table) == ["a.txt", "b.txt", "docs"])
    #expect(fixture.table.accessibilityLabel() == "root")
}

@MainActor @Test func doubleClickOnAFolderRowOpensIt() async throws {
    let fixture = Fixture()
    await settle { fixture.pane.state.isLoaded }
    fixture.table.row = try #require(rowNames(fixture.table).firstIndex(of: "docs"))

    let action = try #require(fixture.table.doubleAction)
    #expect(NSApplication.shared.sendAction(action, to: fixture.table.target, from: fixture.table))

    #expect(fixture.pane.location == Location(path: "/root/docs"))
    await settle { fixture.pane.state.isLoaded }
    #expect(rowNames(fixture.table) == ["inside.txt"])
}

@MainActor @Test func doubleClickOutsideTheRowsOpensNothing() async throws {
    let fixture = Fixture()
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    fixture.table.row = -1

    let action = try #require(fixture.table.doubleAction)
    NSApplication.shared.sendAction(action, to: fixture.table.target, from: fixture.table)

    #expect(fixture.pane.location == Location(path: "/root"))
}

@MainActor @Test func arrowKeysMoveThePaneSelectionAndTheTableShowsIt() async throws {
    let fixture = Fixture()
    await settle { fixture.pane.state.isLoaded }
    let down = try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags)

    fixture.table.keyDown(with: down)
    fixture.table.keyDown(with: down)

    #expect(fixture.pane.selection.members == .only([ExactName("b.txt")]))
    #expect(fixture.table.selectedRowIndexes == [1])
}

@MainActor @Test func cmdDownOpensTheSelectedFolderAndCmdUpGoesBack() async throws {
    let fixture = Fixture()
    await settle { fixture.pane.state.isLoaded }
    fixture.table.selectRowIndexes([2], byExtendingSelection: false)
    await settle { fixture.pane.selection.isSettled }
    #expect(fixture.pane.selection.members == .only([ExactName("docs")]))

    fixture.table.keyDown(
        with: try keyEvent(
            functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags.union(.command)))
    #expect(fixture.pane.location == Location(path: "/root/docs"))
    await settle { fixture.pane.state.isLoaded }

    fixture.table.keyDown(
        with: try keyEvent(
            functionKey(NSUpArrowFunctionKey), modifiers: arrowFlags.union(.command)))
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.location == Location(path: "/root"))
    #expect(fixture.table.selectedRowIndexes == [2])
}

@MainActor @Test func pathBarShowsTheVolumeNameTheListingCarried() async throws {
    let fixture = Fixture()
    await settle { fixture.pane.state.isLoaded }

    #expect(fixture.controller.pathBar.segments.map(\.title) == ["Test Disk", "root"])
}

@MainActor @Test func aPaneThatGivesUpBeforeAnyUpdateShowsItsPathOffline() async throws {
    let lister = GatedLister(["/root": .blockForever])
    lister.releaseAll()
    let clock = ManualClock()
    let pane = Pane(
        location: Location(path: "/root"),
        service: ListingService(lister: lister, clock: clock, rootVolumeName: { "Test Disk" }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: false)
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)

    clock.advance(by: LoadTimeouts.giveUp)
    await settle {
        if case .offline = pane.state { true } else { false }
    }

    #expect(controller.pathBar.segments.map(\.title) == ["Test Disk", "root"])
}

/// A volume name a test can change between loads.
private final class VolumeName: @unchecked Sendable {
    private let lock = NSLock()
    private var name: String

    init(_ name: String) { self.name = name }

    var value: String {
        get { lock.withLock { name } }
        set { lock.withLock { name = newValue } }
    }
}

@MainActor @Test func aRenamedVolumeReachesThePathBarOnTheNextLoad() async throws {
    let volume = VolumeName("Old Disk")
    let fixture = Fixture(rootVolumeName: { volume.value })
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.controller.pathBar.segments.first?.title == "Old Disk")

    volume.value = "New Disk"
    fixture.pane.reload()

    await settle { fixture.controller.pathBar.segments.first?.title == "New Disk" }
    #expect(fixture.controller.pathBar.segments.map(\.title) == ["New Disk", "root"])
}

@MainActor @Test func inAWindowTheListEndsWhereThePathBarStarts() async throws {
    let window = BrowserWindowController(
        location: Location(path: "/root"),
        service: ListingService(lister: StubLister(Fixture.folders)) { "Test Disk" },
        systemActions: StubSystemActions(), settings: untouchedSettings())
    let controller = window.paneViewController
    await settle { controller.pane.state.isLoaded }
    window.window?.contentView?.layoutSubtreeIfNeeded()

    let pane = controller.view.bounds
    let list = controller.listingViewController.view.frame
    let bar = controller.pathBar.frame
    #expect(pane.width > 0 && pane.height > PathBarView.height)
    #expect(bar == NSRect(x: 0, y: 0, width: pane.width, height: PathBarView.height))
    #expect(list == NSRect(x: 0, y: bar.maxY, width: pane.width, height: pane.height - bar.maxY))
    #expect(!list.intersects(bar))
    let header = try #require(controller.listingViewController.tableView.headerView)
    let headerInPane = header.convert(header.bounds, to: controller.view)
    #expect(!headerInPane.isEmpty)
    #expect(pane.contains(headerInPane))
    #expect(!headerInPane.intersects(bar))
}

@MainActor @Test func clickingAPathBarSegmentGoesThereWithTheChildSelected() async throws {
    let fixture = Fixture()
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.navigate(to: Location(path: "/root/docs"))
    await settle { fixture.pane.state.isLoaded }

    fixture.controller.pathBar.segments[1].performClick(nil)

    #expect(fixture.pane.location == Location(path: "/root"))
    await settle { fixture.pane.state.isLoaded }
    #expect(fixture.pane.selection.members == .only([ExactName("docs")]))
    #expect(fixture.table.selectedRowIndexes == [2])
}

@MainActor @Test func pathBarChangesInTheSameUpdateAsTheNewFoldersFirstRows() async throws {
    let lister = GatedLister(Fixture.folders.mapValues { .batches([$0]) })
    let fixture = Fixture(lister: lister)
    lister.release("/root")
    await settle { fixture.pane.state.isLoaded }
    // What each pane change left on screen, recorded as the views finish updating for it, in
    // the run loop pass that changed the pane and so before the window next draws.
    var shown: [(rows: [String], path: Location?)] = []
    fixture.controller.onShow = {
        shown.append((rowNames(fixture.table), fixture.controller.pathBar.location))
    }

    fixture.pane.navigate(to: Location(path: "/root/docs"))
    lister.release("/root/docs")
    await settle { fixture.pane.state.isLoaded }

    let firstRows = try #require(shown.firstIndex { $0.rows == ["inside.txt"] })
    #expect(shown[firstRows].path == Location(path: "/root/docs"))
    #expect(shown[..<firstRows].allSatisfy { $0.path == Location(path: "/root") })
}

@MainActor @Test func fileCreatedInThePanesFolderShowsUp() async throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let url = folder.url
    try await Task.detached { try Data().write(to: url.appending(path: "old.txt")) }.value
    let pane = Pane(
        location: Location(path: url.path), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings(),
        isFocused: true)
    let table = ListingTableView()
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: table, monitorsFolders: true)
    _ = controller.view
    await settle { pane.state.isLoaded && pane.monitor != nil }
    #expect(rowNames(table) == ["old.txt"])

    try await Task.detached { try Data().write(to: url.appending(path: "new.txt")) }.value

    await settle { rowNames(table) == ["new.txt", "old.txt"] }
    #expect(rowNames(table) == ["new.txt", "old.txt"])
}

@MainActor @Test func aCommandThatOpensAFolderStartsANewQueryThere() async throws {
    let fixture = Fixture()
    fixture.table.beep = {}
    await settle { fixture.pane.state.isLoaded }

    fixture.table.keyDown(with: try keyEvent("d"))
    #expect(fixture.pane.selection.members == .only([ExactName("docs")]))
    fixture.table.keyDown(
        with: try keyEvent(
            functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags.union(.command)))
    await settle { fixture.pane.state.isLoaded }
    fixture.table.keyDown(with: try keyEvent("i"))

    #expect(fixture.table.typeSelect.query == "i")
    #expect(fixture.pane.selection.members == .only([ExactName("inside.txt")]))
}

/// A path bar click moves the pane without a command.
@MainActor @Test func aNewLocationStartsANewQuery() async throws {
    let fixture = Fixture()
    fixture.table.beep = {}
    await settle { fixture.pane.state.isLoaded }

    fixture.table.keyDown(with: try keyEvent("d"))
    fixture.pane.navigate(to: Location(path: "/root/docs"))
    await settle { fixture.pane.state.isLoaded }
    fixture.table.keyDown(with: try keyEvent("i"))

    #expect(fixture.table.typeSelect.query == "i")
    #expect(fixture.pane.selection.members == .only([ExactName("inside.txt")]))
}

// MARK: Column view

/// A pane at `/root` over `Fixture.folders` in a window that is never shown, the list's table
/// first responder, loaded.
@MainActor
private final class WindowFixture {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    let fixture: Fixture

    init() async {
        fixture = Fixture()
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(fixture.controller.view)
        window.makeFirstResponder(fixture.table)
        let pane = fixture.pane
        await settle { pane.state.isLoaded }
    }

    var pane: Pane { fixture.pane }
    var controller: PaneViewController { fixture.controller }

    /// The table that has the keys.
    var keyTable: ListingTableView {
        guard let table = window.firstResponder as? ListingTableView else {
            preconditionFailure(
                "no table has the keys: \(String(describing: window.firstResponder))")
        }
        return table
    }

    func press(_ key: Int, _ modifiers: NSEvent.ModifierFlags = []) throws {
        keyTable.keyDown(
            with: try keyEvent(functionKey(key), modifiers: arrowFlags.union(modifiers)))
    }

    func press(_ characters: String, _ modifiers: NSEvent.ModifierFlags = []) throws {
        keyTable.keyDown(with: try keyEvent(characters, modifiers: modifiers))
    }

    func waitForColumns() async {
        let pane = pane
        await settle {
            pane.columnTrail?.columns.allSatisfy { $0.pane.state.isLoaded } ?? false
        }
    }
}

@MainActor @Test func cmd3ShowsColumnsWhoseFocusedTableTakesTheKeysAndCmd1ShowsTheList()
    async throws
{
    let setup = await WindowFixture()
    let list = setup.controller.listingViewController.view
    let columns = setup.controller.columnViewController.view

    try setup.press("3", .command)
    await setup.waitForColumns()

    #expect(setup.pane.viewMode == .column)
    #expect(list.isHidden && !columns.isHidden)
    #expect(setup.window.firstResponder === setup.controller.keyView)
    #expect(setup.keyTable !== setup.fixture.table)
    #expect(setup.controller.spinner.isHidden)

    // a.txt, b.txt, docs: the third row opens a second column, and → moves the keys into it.
    for _ in 0..<3 { try setup.press(NSDownArrowFunctionKey) }
    await setup.waitForColumns()
    #expect(setup.pane.columnTrail?.columns.count == 2)
    try setup.press(NSRightArrowFunctionKey)

    let second = try #require(setup.controller.columnViewController.columnControllers.last)
    #expect(setup.window.firstResponder === second.tableView)
    #expect(second.tableView.selectedRowIndexes == [0])
    #expect(setup.controller.pathBar.location == Location(path: "/root/docs"))

    try setup.press("1", .command)
    await settle { setup.pane.state.isLoaded }

    #expect(setup.pane.viewMode == .list)
    #expect(!list.isHidden && columns.isHidden)
    #expect(setup.window.firstResponder === setup.fixture.table)
    #expect(setup.pane.location == Location(path: "/root/docs"))
    #expect(rowNames(setup.fixture.table) == ["inside.txt"])
}

@MainActor @Test func theFilterNarrowsTheFocusedColumn() async throws {
    let setup = await WindowFixture()
    try setup.press("3", .command)
    await setup.waitForColumns()
    let column = try #require(setup.pane.columnTrail?.focused.pane)

    try setup.press("f", .command)
    let editor = try #require(setup.window.firstResponder as? NSTextView)
    editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))

    #expect(column.filter.text == "b")
    #expect(setup.pane.filter.isEmpty)
    let table = try #require(setup.controller.columnViewController.focusedController?.tableView)
    await settle { rowNames(table) == ["b.txt"] }
}

/// The filter belongs to the column it was typed in: the field shows the focused column's.
@MainActor @Test func theFilterFieldFollowsTheFocusedColumnsFilter() async throws {
    let setup = await WindowFixture()
    try setup.press("3", .command)
    await setup.waitForColumns()
    let columns = setup.controller.columnViewController
    try setup.press("f", .command)
    let editor = try #require(setup.window.firstResponder as? NSTextView)
    editor.insertText("d", replacementRange: NSRange(location: NSNotFound, length: 0))
    let first = try #require(columns.focusedController)
    await settle { rowNames(first.tableView) == ["docs"] }
    // ↓ in the field selects docs, which opens its column.
    #expect(
        setup.controller.filterBar.control(
            setup.controller.filterBar.field, textView: editor,
            doCommandBy: #selector(NSResponder.moveDown(_:))))
    await setup.waitForColumns()
    let second = try #require(columns.columnControllers.last)
    #expect(columns.columnControllers.count == 2)

    // A click in the second column.
    #expect(setup.window.makeFirstResponder(second.tableView))

    #expect(setup.pane.commandPane === second.pane)
    #expect(setup.controller.filterBar.isHidden)
    #expect(second.pane.filter.isEmpty)
    #expect(first.pane.filter.text == "d")

    #expect(setup.window.makeFirstResponder(first.tableView))

    #expect(!setup.controller.filterBar.isHidden)
    #expect(setup.controller.filterBar.field.stringValue == "d")
    #expect(second.pane.filter.isEmpty)
}

@MainActor @Test func viewMenuChecksTheFocusedPanesViewMode() async throws {
    let setup = await WindowFixture()
    let asList = NSMenuItem(
        title: "", action: #selector(ListingTableView.runMenuCommand(_:)), keyEquivalent: "")
    asList.representedObject = ViewCommands.asList.id
    let asColumns = NSMenuItem(
        title: "", action: #selector(ListingTableView.runMenuCommand(_:)), keyEquivalent: "")
    asColumns.representedObject = ViewCommands.asColumns.id

    #expect(setup.keyTable.validateMenuItem(asList))
    #expect(setup.keyTable.validateMenuItem(asColumns))
    #expect(asList.state == .on && asColumns.state == .off)

    try setup.press("3", .command)
    await setup.waitForColumns()
    _ = setup.keyTable.validateMenuItem(asList)
    _ = setup.keyTable.validateMenuItem(asColumns)

    #expect(asList.state == .off && asColumns.state == .on)
}

@MainActor @Test func aFileCreatedInAColumnsFolderShowsUpInThatColumn() async throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let url = folder.url
    try await Task.detached {
        try FileManager.default.createDirectory(
            at: url.appending(path: "sub"), withIntermediateDirectories: false)
    }.value
    let pane = Pane(
        location: Location(path: url.path), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        selecting: ExactName("sub"))
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: true)
    _ = controller.view
    await settle { pane.state.isLoaded && pane.monitor != nil }

    pane.setViewMode(.column)
    let trail = try #require(pane.columnTrail)
    await settle {
        trail.columns.count == 2 && trail.columns.allSatisfy { $0.pane.monitor != nil }
    }
    #expect(pane.monitor == nil)

    try await Task.detached { try Data().write(to: url.appending(path: "sub/new.txt")) }.value

    let tables = controller.columnViewController.columnControllers.map(\.tableView)
    await settle { tables.count == 2 && rowNames(tables[1]) == ["new.txt"] }
    #expect(rowNames(tables[1]) == ["new.txt"])
    #expect(pane.monitor == nil)
}

/// Back in the list at the folder it left, the list watches the folder again.
@MainActor @Test func cmd3ThenCmd1AtTheSameFolderStartsTheListsMonitorAgain() async throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let url = folder.url
    try await Task.detached { try Data().write(to: url.appending(path: "old.txt")) }.value
    let pane = Pane(
        location: Location(path: url.path), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    let table = ListingTableView()
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: table, monitorsFolders: true)
    _ = controller.view
    await settle { pane.state.isLoaded && pane.monitor != nil }

    pane.setViewMode(.column)
    #expect(pane.monitor == nil)
    pane.setViewMode(.list)
    #expect(pane.location == Location(path: url.path))
    await settle { pane.state.isLoaded && pane.monitor != nil }
    #expect(pane.monitor != nil)

    try await Task.detached { try Data().write(to: url.appending(path: "new.txt")) }.value

    await settle { rowNames(table) == ["new.txt", "old.txt"] }
    #expect(rowNames(table) == ["new.txt", "old.txt"])
}

@MainActor @Test func quickLookOpensOnTheFocusedColumnNotTheList() async throws {
    let setup = await WindowFixture()
    setup.fixture.table.beep = { Issue.record("the list beeped") }
    setup.controller.listingViewController.quickLook.isPanelOpen = { false }
    setup.controller.listingViewController.quickLook.openPanel = {
        Issue.record("the list opened Quick Look")
    }
    try setup.press("3", .command)
    await setup.waitForColumns()
    try setup.press(NSDownArrowFunctionKey)
    let column = try #require(setup.controller.columnViewController.focusedController)
    var opened = 0
    column.quickLook.isPanelOpen = { false }
    column.quickLook.openPanel = { opened += 1 }

    try setup.press(" ")

    #expect(opened == 1)
}

/// A query typed in one column doesn't carry on when the keys come back to it from another.
@MainActor @Test func typeSelectStartsANewQueryWhenTheKeysMoveToAnotherColumn() async throws {
    let setup = await WindowFixture()
    try setup.press("3", .command)
    await setup.waitForColumns()
    let columns = setup.controller.columnViewController
    let first = try #require(columns.focusedController)
    first.tableView.beep = {}

    try setup.press("d")
    #expect(first.tableView.typeSelect.query == "d")
    await setup.waitForColumns()
    let second = try #require(columns.columnControllers.last)
    #expect(second !== first)

    // Clicks in the second column, then back in the first.
    #expect(setup.window.makeFirstResponder(second.tableView))
    #expect(setup.pane.commandPane === second.pane)
    #expect(setup.window.makeFirstResponder(first.tableView))
    #expect(setup.pane.commandPane === first.pane)

    #expect(first.tableView.typeSelect.query == "")
}

/// Leaving a folder with text in the filter field doesn't filter the new folder by it: the field
/// is emptied before it gives up the keys, which sends its text once more.
@MainActor @Test func leavingAFolderWhileTheFilterFieldHasTheKeysLeavesTheNewFolderUnfiltered()
    async throws
{
    let setup = await WindowFixture()
    try setup.press("f", .command)
    let editor = try #require(setup.window.firstResponder as? NSTextView)
    editor.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(setup.pane.filter.text == "a")

    setup.pane.navigate(to: Location(path: "/root/docs"))

    #expect(setup.pane.filter.isEmpty)
    #expect(setup.window.firstResponder === setup.fixture.table)
    await settle { setup.pane.state.isLoaded }
    #expect(rowNames(setup.fixture.table) == ["inside.txt"])
}
