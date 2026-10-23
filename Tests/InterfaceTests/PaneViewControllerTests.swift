import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Interface

extension ListingState {
    var isLoaded: Bool { if case .loaded = self { true } else { false } }
    var isOffline: Bool { if case .offline = self { true } else { false } }
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

    /// `clock` times the loads and the status view's spinner.
    init(
        lister: any Lister = StubLister(Fixture.folders), monitors: Bool = false,
        rootVolumeName: @escaping @Sendable () -> String = { "Test Disk" },
        clock: ManualClock = ManualClock(), at path: String = "/root"
    ) {
        pane = Pane(
            location: Location(path: path),
            service: ListingService(lister: lister, clock: clock, rootVolumeName: rootVolumeName),
            systemActions: actions, settings: untouchedSettings(), isFocused: true)
        table = ClickedRowTableView()
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: table, monitorsFolders: monitors,
            status: PaneStatusView(clock: clock))
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    }

    static let folders = [
        "/root": [folder("docs"), file("a.txt"), file("b.txt")],
        "/root/docs": [file("inside.txt")],
        "/": [folder("root")],
    ]
}

@MainActor @Test func showsASpinnerOnceALoadPassesTheDelayAndTheTableWhenLoaded() async throws {
    let lister = GatedLister(Fixture.folders.mapValues { .batches([$0]) })
    let clock = ManualClock()
    let fixture = Fixture(lister: lister, clock: clock)
    let spinner = fixture.controller.status.spinner

    #expect(spinner.isHidden)
    // The delay reads the clock when its task starts, which can be after an advance made now.
    await settle { clock.waitingSleeps >= 1 }
    clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !spinner.isHidden }
    #expect(spinner.accessibilityLabel() == "Loading root")

    lister.releaseAll()
    await settle { fixture.pane.state.isLoaded }

    #expect(spinner.isHidden)
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

@MainActor @Test func twoPanesSpinnersAreIndependent() async throws {
    let lister = GatedLister([
        "/Volumes/fast": .batches([[file("a.txt")]]),
        "/Volumes/hung": .blockForever,
    ])
    lister.release("/Volumes/fast")
    let clock = ManualClock()
    let fast = Fixture(lister: lister, clock: clock, at: "/Volumes/fast")
    let hung = Fixture(lister: lister, clock: clock, at: "/Volumes/hung")
    await settle { fast.pane.state.isLoaded }

    clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !hung.controller.status.spinner.isHidden }
    #expect(fast.controller.status.spinner.isHidden)

    clock.advance(by: LoadTimeouts.slow)
    await settle { !hung.controller.status.note.isHidden }
    #expect(hung.controller.status.note.stringValue == "Test Disk is slow to answer.")
    #expect(fast.controller.status.note.isHidden)
}

@MainActor @Test func inColumnViewThePathBarShowsTheFocusedColumnsState() async throws {
    let lister = GatedLister([
        "/root": .batches([Fixture.folders["/root"] ?? []]),
        "/root/docs": .blockForever,
    ])
    lister.releaseAll()
    let clock = ManualClock()
    let fixture = Fixture(lister: lister, clock: clock)
    let status = fixture.controller.status
    fixture.pane.setViewMode(.column)
    let trail = try #require(fixture.pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }

    trail.columns[0].pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.count == 2 }
    #expect(await lister.waitForCall("/root/docs"))
    clock.advance(by: LoadTimeouts.slow)
    await settle {
        if case .slow = trail.columns[1].pane.state { true } else { false }
    }
    #expect(status.note.isHidden)

    trail.moveRight()

    await settle { !status.note.isHidden }
    #expect(status.note.stringValue == "Test Disk is slow to answer.")
}

/// Whether each call of a kind ran on the main thread, recorded from the calling thread.
private final class MainThreadRecord: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []

    func record() { lock.withLock { calls.append(Thread.isMainThread) } }
    var all: [Bool] { lock.withLock { calls } }
}

/// A share whose read never returns takes the pane through the spinner, slow and offline, and
/// neither the read nor any volume or mount table read runs on the main thread, where it would
/// block the app for as long as the share doesn't answer.
@MainActor @Test func aPaneOnAShareThatNeverAnswersReadsNothingOnTheMainThread() async throws {
    let lister = GatedLister(["/Volumes/nas": .blockForever])
    lister.releaseAll()
    let clock = ManualClock()
    let volumeReads = MainThreadRecord()
    let mountTableReads = MainThreadRecord()
    let nas = VolumeIdentity(device: "//me@nas/nas", mountPoint: "/Volumes/nas", kind: .network)
    let service = ListingService(
        lister: lister, clock: clock, rootVolumeName: { "Test Disk" },
        volumeOf: { _ in
            volumeReads.record()
            return nas
        },
        mountedVolumes: {
            mountTableReads.record()
            return [nas]
        })
    let pane = Pane(
        location: Location(path: "/Volumes/nas"), service: service,
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: false,
        status: PaneStatusView(clock: clock))
    controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
    let note = controller.status.note

    // The read has started, so the volume and mount table reads before it are done.
    #expect(await lister.waitForCall("/Volumes/nas"))
    let spinner = controller.status.spinner
    clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !spinner.isHidden }
    clock.advance(by: LoadTimeouts.slow - LoadTimeouts.spinnerDelay)
    await settle { note.stringValue == "nas is slow to answer." }
    clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { note.stringValue == "nas is offline." }

    #expect(lister.calls.count == 1)
    #expect(lister.calls.allSatisfy { !$0.onMainThread })
    #expect(!volumeReads.all.isEmpty)
    #expect(volumeReads.all.allSatisfy { !$0 })
    #expect(!mountTableReads.all.isEmpty)
    #expect(mountTableReads.all.allSatisfy { !$0 })
}

@MainActor @Test func aVolumeThatUnmountsBeforeThePanesFirstUpdateShowsItOffline() async throws {
    let mountPoint = "/pane-status-\(UUID().uuidString)"
    let lister = GatedLister([mountPoint: .blockForever])
    lister.releaseAll()
    let fixture = Fixture(lister: lister, at: mountPoint)
    #expect(await lister.waitForCall(mountPoint))

    VolumeEvents.didUnmount(at: mountPoint)

    #expect(fixture.pane.state.isOffline)
    #expect(
        fixture.controller.status.note.stringValue
            == "\(Location(path: mountPoint).name) is offline.")
    // No update has named the root volume yet, so the bar has nothing to show.
    #expect(fixture.controller.pathBar.segments.isEmpty)
}

@MainActor @Test func theStatusTakesAtMostSixTenthsOfThePathBarRow() async throws {
    let lister = GatedLister(["/Volumes/nas": .blockForever])
    lister.releaseAll()
    let fixture = Fixture(lister: lister, at: "/Volumes/nas")
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 500, height: 300), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    fixture.controller.view.frame = window.contentView?.bounds ?? .zero
    window.contentView?.addSubview(fixture.controller.view)
    let status = fixture.controller.status
    status.show(
        .offline(nil), location: Location(path: "/Volumes/nas"),
        volumeName: String(repeating: "a very long share name ", count: 20))

    window.contentView?.layoutSubtreeIfNeeded()

    let width = fixture.controller.view.bounds.width
    #expect(status.frame.width <= width * 0.6 + 0.5)
    #expect(status.frame.width >= width * 0.6 - 0.5)
    #expect(fixture.controller.pathBar.frame.maxX == status.frame.minX)
}

@MainActor @Test func theNoteGivesWayBeforeThePathBar() {
    let status = PaneStatusView()

    #expect(
        status.note.contentCompressionResistancePriority(for: .horizontal)
            < NSLayoutConstraint.Priority.defaultHigh)
    #expect(
        status.note.contentCompressionResistancePriority(for: .horizontal)
            < status.spinner.contentCompressionResistancePriority(for: .horizontal))
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
    let status = controller.status.frame
    #expect(bar == NSRect(x: 0, y: 0, width: status.minX, height: PathBarView.height))
    #expect(status.maxX == pane.width && status.minY == 0 && status.height == bar.height)
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
    #expect(setup.controller.status.spinner.isHidden)

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

/// The temporary folder stands for a volume's mount point: volume events place panes by path.
@MainActor @Test func aRemountedVolumeIsWatchedAgainInTheList() async throws {
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

    VolumeEvents.didUnmount(at: url.path)
    #expect(pane.monitor == nil)
    VolumeEvents.didMount(at: url.path)
    await settle { pane.state.isLoaded && pane.monitor != nil }

    try await Task.detached { try Data().write(to: url.appending(path: "new.txt")) }.value

    await settle { rowNames(table) == ["new.txt", "old.txt"] }
    #expect(rowNames(table) == ["new.txt", "old.txt"])
}

@MainActor @Test func aRemountedVolumeIsWatchedAgainInEachColumn() async throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let url = folder.url
    let pane = Pane(
        location: Location(path: url.path), service: ListingService(),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: ListingTableView(), monitorsFolders: true)
    _ = controller.view
    let column = try #require(pane.columnTrail?.columns.first?.pane)
    await settle { column.state.isLoaded && column.monitor != nil }

    VolumeEvents.didUnmount(at: url.path)
    #expect(column.monitor == nil)
    VolumeEvents.didMount(at: url.path)
    await settle { column.state.isLoaded && column.monitor != nil }

    try await Task.detached { try Data().write(to: url.appending(path: "new.txt")) }.value

    let table = try #require(controller.columnViewController.columnControllers.first?.tableView)
    await settle { rowNames(table) == ["new.txt"] }
    #expect(rowNames(table) == ["new.txt"])
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

@MainActor @Test func theTablesKeysFollowTheCommanderFKeySetting() throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let settings = storedSettings(in: folder)
    let pane = Pane(
        location: Location(path: "/root"),
        service: ListingService(lister: StubLister(Fixture.folders)),
        systemActions: StubSystemActions(), settings: settings)
    let table = ListingTableView()
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: table, monitorsFolders: false)
    let f5 = KeyChord(.function(5))
    #expect(table.registry.command(for: f5) == nil)

    settings.commanderFKeys = true
    #expect(table.registry.command(for: f5)?.id == FileCommands.copyToOtherPane.id)

    settings.commanderFKeys = false
    #expect(table.registry.command(for: f5) == nil)
    withExtendedLifetime(controller) {}
}
