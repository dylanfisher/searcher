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

/// `folders`' entries, where `/root` also holds `unreadable` entries whose names aren't UTF-8,
/// which a `DirectoryLister` leaves out and counts.
private struct UnreadableNamesLister: Lister {
    let folders: StubLister
    let unreadable: Int

    func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
        _ = try listCountingUnreadableNames(path, onBatch: onBatch)
    }

    func listCountingUnreadableNames(
        _ path: String, onBatch: ([DirectoryEntry]) throws -> Void
    ) throws -> Int {
        try folders.list(path, onBatch: onBatch)
        return path == "/root" ? unreadable : 0
    }
}

@MainActor @Test func aFolderWithUnreadableNamesSaysHowManyItLeavesOut() async throws {
    let fixture = Fixture(
        lister: UnreadableNamesLister(folders: StubLister(Fixture.folders), unreadable: 2))
    await settle { fixture.pane.state.isLoaded }

    #expect(rowNames(fixture.table) == ["a.txt", "b.txt", "docs"])
    #expect(!fixture.controller.status.note.isHidden)
    #expect(
        fixture.controller.status.note.stringValue
            == "2 items with unreadable names aren't shown.")

    fixture.pane.navigate(to: Location(path: "/root/docs"))
    await settle { fixture.pane.location.path == "/root/docs" && fixture.pane.state.isLoaded }
    #expect(fixture.controller.status.note.isHidden)
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

/// ↓ as AppKit sends it, first pressed or repeating while held.
@MainActor
private func downKey(isARepeat: Bool) throws -> NSEvent {
    try keyEvent(
        functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags, keyCode: 125,
        isARepeat: isARepeat)
}

/// The table hands a key's repeat flag to the command, so a held ↓ is one selection step and
/// each separate press its own.
@MainActor @Test func aHeldArrowIsOneSelectionStepAndEachPressItsOwn() async throws {
    let fixture = Fixture()
    let tab = Tab(pane: fixture.pane)
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    fixture.table.keyDown(with: try downKey(isARepeat: false))
    fixture.table.keyDown(with: try downKey(isARepeat: true))
    #expect(fixture.pane.selection.cursor == ExactName("docs"))
    tab.undoSelection()
    #expect(fixture.pane.selection.cursor == ExactName("a.txt"))
    #expect(!tab.canUndoSelection)

    fixture.table.keyDown(with: try downKey(isARepeat: false))
    fixture.table.keyDown(with: try downKey(isARepeat: false))
    tab.undoSelection()
    #expect(fixture.pane.selection.cursor == ExactName("b.txt"))
    #expect(tab.canUndoSelection)
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
        "/": .batches([Fixture.folders["/"] ?? []]),
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

    trail.columns[1].pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.count == 3 }
    #expect(await lister.waitForCall("/root/docs"))
    clock.advance(by: LoadTimeouts.slow)
    await settle {
        if case .slow = trail.columns[2].pane.state { true } else { false }
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
    let window = testWindow(size: NSSize(width: 500, height: 300))
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
    let settings = untouchedSettings()
    let window = BrowserWindowController(
        location: Location(path: "/root"),
        service: ListingService(lister: StubLister(Fixture.folders)) { "Test Disk" },
        systemActions: StubSystemActions(), settings: settings,
        favorites: Favorites(settings: settings), volumes: StubSidebarVolumes().list())
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

/// In column view a click on a folder whose column shows moves the keys to that column and closes
/// the columns right of it, leaving the folder it came from as the cursor; Back has a step
/// (0103-column-trail-from-the-root.md).
@MainActor @Test func clickingAPathBarSegmentInColumnViewShowsThatFoldersColumnLast() async throws {
    let fixture = Fixture(at: "/root/docs")
    await settle { fixture.pane.state.isLoaded }
    fixture.pane.setViewMode(.column)
    let trail = try #require(fixture.pane.columnTrail)
    await settle {
        trail.columns.allSatisfy { $0.pane.state.isLoaded }
            && fixture.controller.pathBar.location == Location(path: "/root/docs")
    }
    let columns = trail.columns.map(\.pane)
    #expect(fixture.controller.pathBar.segments.map(\.title) == ["Test Disk", "root", "docs"])

    fixture.controller.pathBar.segments[1].performClick(nil)

    #expect(trail.focusedIndex == 1)
    #expect(fixture.pane.location == Location(path: "/root"))
    #expect(trail.columns.map(\.pane).elementsEqual(columns.prefix(2), by: ===))
    #expect(trail.focused.pane.selection.isEmpty)
    #expect(trail.focused.pane.selection.cursor == ExactName("docs"))
    #expect(fixture.pane.canGoBack)
    #expect(fixture.controller.pathBar.location == Location(path: "/root"))
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
    let window = testWindow(size: NSSize(width: 800, height: 400))
    let fixture: Fixture

    init(folders: [String: [DirectoryEntry]] = Fixture.folders) async {
        fixture = Fixture(lister: StubLister(folders))
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
    // The column opens once the keys pause.
    for _ in 0..<3 { try setup.press(NSDownArrowFunctionKey) }
    await settle { setup.pane.columnTrail?.columns.count == 3 }
    await setup.waitForColumns()
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

/// ← and → scroll the selected row of the column they move the keys into into view, as ↑ and
/// ↓ do and as Finder does, though the column was scrolled away from it since.
@MainActor @Test func arrowsIntoAColumnScrollItsSelectedRowIntoView() async throws {
    let files = (0..<60).map { file(String(format: "f%02d.txt", $0)) }
    let setup = await WindowFixture(folders: [
        "/root": [folder("docs")] + files, "/root/docs": files, "/": [folder("root")],
    ])
    try setup.press("3", .command)
    await setup.waitForColumns()
    let columns = setup.controller.columnViewController
    // docs, the first row, opens its column once the keys pause; → selects its first row.
    try setup.press(NSDownArrowFunctionKey)
    await settle { setup.pane.columnTrail?.columns.count == 3 }
    await setup.waitForColumns()
    setup.window.contentView?.layoutSubtreeIfNeeded()
    let root = columns.columnControllers[1].tableView
    let docs = columns.columnControllers[2].tableView
    docs.scrollRowToVisible(59)
    try setup.press(NSRightArrowFunctionKey)

    #expect(setup.window.firstResponder === docs)
    #expect(root.selectedRowIndexes == [0] && docs.selectedRowIndexes == [0])
    #expect(docs.visibleRect.contains(docs.rect(ofRow: 0)))

    root.scrollRowToVisible(60)
    #expect(!root.visibleRect.contains(root.rect(ofRow: 0)))
    try setup.press(NSLeftArrowFunctionKey)

    #expect(setup.window.firstResponder === root)
    #expect(root.visibleRect.contains(root.rect(ofRow: 0)))

    docs.scrollRowToVisible(59)
    #expect(!docs.visibleRect.contains(docs.rect(ofRow: 0)))
    try setup.press(NSRightArrowFunctionKey)

    #expect(setup.window.firstResponder === docs)
    #expect(docs.selectedRowIndexes == [0])
    #expect(docs.visibleRect.contains(docs.rect(ofRow: 0)))
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
    #expect(columns.columnControllers.count == 3)

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

/// A View menu item for `command`, as `MainMenuBuilder` makes one.
@MainActor
private func menuItem(_ command: Command) -> NSMenuItem {
    let item = NSMenuItem(
        title: command.title, action: #selector(ListingTableView.runMenuCommand(_:)),
        keyEquivalent: "")
    item.representedObject = command.id
    return item
}

/// Ctrl-Opt-1 on `docs`'s column sorts it Z to A; the column it opens starts A to Z.
@MainActor @Test func aColumnOpenedFromAReversedColumnSortsByNameAscending() async throws {
    let setup = await WindowFixture()
    try setup.press("3", .command)
    await setup.waitForColumns()
    let root = try #require(setup.pane.columnTrail?.focused.pane)
    let table = try #require(setup.controller.columnViewController.focusedController?.tableView)

    try setup.press("1", [.control, .option])
    await settle { rowNames(table) == ["docs", "b.txt", "a.txt"] }
    try setup.press(NSDownArrowFunctionKey)
    #expect(root.selection.cursor == ExactName("docs"))
    await settle { setup.pane.columnTrail?.columns.count == 3 }
    await setup.waitForColumns()
    try setup.press(NSRightArrowFunctionKey)

    let docs = try #require(setup.pane.columnTrail?.focused.pane)
    #expect(docs.location == Location(path: "/root/docs"))
    #expect(docs.sortColumn == .name && docs.sortAscending)
    #expect(!root.sortAscending)
}

/// A column shows names only, so it sorts by Name only: the other sort keys and Sort by Next
/// Column do nothing there and their items are off. The list sorts by any of its headers.
@MainActor @Test func columnsSortByNameOnlyAndTheListByEveryHeader() async throws {
    let setup = await WindowFixture()
    let name = menuItem(ViewCommands.sortByName)
    let reverse = menuItem(ViewCommands.reverseSortDirection)
    let others = [
        ViewCommands.sortBySize, ViewCommands.sortByDateModified, ViewCommands.sortByKind,
        ViewCommands.sortByNextColumn,
    ].map(menuItem)
    for item in [name, reverse] + others {
        #expect(setup.keyTable.validateMenuItem(item), "\(item.title)")
    }
    #expect(name.state == .on && others[0].state == .off)

    try setup.press("3", .command)
    await setup.waitForColumns()
    let column = try #require(setup.pane.columnTrail?.focused.pane)
    for key in ["2", "3", "4"] { try setup.press(key, [.control, .option]) }
    try setup.press("p", [.option, .command])

    #expect(column.sortColumn == .name && column.sortAscending)
    #expect(setup.keyTable.validateMenuItem(name))
    #expect(setup.keyTable.validateMenuItem(reverse))
    for item in others {
        #expect(!setup.keyTable.validateMenuItem(item), "\(item.title)")
    }
    #expect(name.state == .on)
    try setup.press("p", [.option, .command, .shift])
    #expect(column.sortColumn == .name && !column.sortAscending)

    try setup.press("1", .command)
    await settle { setup.pane.state.isLoaded }
    try setup.press("2", [.control, .option])
    #expect(setup.pane.sortColumn == .size)
    for item in [name] + others {
        #expect(setup.keyTable.validateMenuItem(item), "\(item.title)")
    }
    #expect(others[0].state == .on && name.state == .off)
}

/// The list keeps its own sort while the pane shows columns, whatever the columns sort by.
@MainActor @Test func theListsSortSurvivesAVisitToColumnView() async throws {
    let setup = await WindowFixture()
    try setup.press("2", [.control, .option])
    #expect(setup.pane.sortColumn == .size && !setup.pane.sortAscending)

    try setup.press("3", .command)
    await setup.waitForColumns()
    let trail = try #require(setup.pane.columnTrail)
    #expect(trail.columns.allSatisfy { $0.pane.sortColumn == .name && $0.pane.sortAscending })
    try setup.press("1", [.control, .option])
    #expect(!trail.focused.pane.sortAscending)
    try setup.press("1", .command)
    await settle { setup.pane.state.isLoaded }

    #expect(setup.pane.sortColumn == .size && !setup.pane.sortAscending)
    #expect(setup.pane.state.listing?.column == .size)
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
    // The ancestors above the folder are left out: they include the real temporary directory,
    // which can hold tens of thousands of entries and list for longer than a settle waits.
    await settle {
        trail.columns.last?.pane.location.path == url.path + "/sub"
            && trail.columns.suffix(2).allSatisfy { $0.pane.monitor != nil }
    }
    #expect(pane.monitor == nil)

    try await Task.detached { try Data().write(to: url.appending(path: "sub/new.txt")) }.value

    let tables = controller.columnViewController.columnControllers.map(\.tableView)
    await settle { tables.last.map(rowNames) == ["new.txt"] }
    #expect(tables.last.map(rowNames) == ["new.txt"])
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
    let column = try #require(pane.columnTrail?.columns.last?.pane)
    await settle { column.state.isLoaded && column.monitor != nil }

    VolumeEvents.didUnmount(at: url.path)
    #expect(column.monitor == nil)
    VolumeEvents.didMount(at: url.path)
    await settle { column.state.isLoaded && column.monitor != nil }

    try await Task.detached { try Data().write(to: url.appending(path: "new.txt")) }.value

    let table = try #require(controller.columnViewController.columnControllers.last?.tableView)
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
    // The folder typed to opens its column once the keys pause.
    await settle { setup.pane.columnTrail?.columns.count == 3 }
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

/// Until the Settings window can change them, shortcuts are set with `defaults write`; the
/// pane's keys follow what is stored (docs/decisions/0106-primary-and-alternate-shortcuts.md).
@MainActor @Test func aShortcutWrittenToTheDefaultsChangesWhatAKeyRunsInThePane() async throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let defaults = temporarySuite(in: folder.url.path)
    defaults.set(["view.toggleHidden": ["primary": "cmd+j"]], forKey: "shortcuts")
    let settings = Settings(defaults: defaults, log: unexpectedSettingsLog)
    let pane = Pane(
        location: Location(path: "/root"),
        service: ListingService(lister: StubLister(Fixture.folders)),
        systemActions: StubSystemActions(), settings: settings, isFocused: true)
    let table = ListingTableView()
    table.beep = {}
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: table, monitorsFolders: false)
    await settle { pane.state.isLoaded }

    table.keyDown(with: try keyEvent(".", modifiers: [.command, .shift]))
    #expect(!settings.showHidden)

    table.keyDown(with: try keyEvent("j", modifiers: .command))
    #expect(settings.showHidden)
    withExtendedLifetime(controller) {}
}

/// ↓ in the filter field is the field's own key: it selects the next row even after the user
/// took ↓ from Select Next Row and gave it to Open.
@MainActor @Test func theFilterFieldsArrowsMoveTheRowWhateverTheShortcuts() async throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let defaults = temporarySuite(in: folder.url.path)
    defaults.set(
        ["selection.next": ["primary": ""], "navigation.open": ["alternate": "down"]],
        forKey: "shortcuts")
    let settings = Settings(defaults: defaults, log: unexpectedSettingsLog)
    let pane = Pane(
        location: Location(path: "/root"),
        service: ListingService(lister: StubLister(Fixture.folders)),
        systemActions: StubSystemActions(), settings: settings, isFocused: true)
    let table = ListingTableView()
    let controller = PaneViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
        tableView: table, monitorsFolders: false)
    await settle { pane.state.isLoaded }
    #expect(table.registry.command(for: KeyChord(.down))?.id == NavigationCommands.open.id)
    let bar = controller.filterBar

    for _ in 0..<2 {
        #expect(
            bar.control(
                bar.field, textView: NSTextView(),
                doCommandBy: #selector(NSResponder.moveDown(_:))))
    }

    #expect(pane.selection.members == .only([ExactName("b.txt")]))
    #expect(pane.location == Location(path: "/root"))
}

/// `keyboardFocusIndicatorColor` is a lighter blue in Dark Mode. The ring is a layer's border,
/// whose `CGColor` is fixed when it is set, so it is resolved again when the appearance changes.
@MainActor @Test func theFocusRingTakesTheColorOfThePanesAppearance() throws {
    let fixture = Fixture()
    let view = fixture.controller.view
    func ring(in name: NSAppearance.Name) throws -> CGColor {
        var color: CGColor?
        try #require(NSAppearance(named: name)).performAsCurrentDrawingAppearance {
            color = NSColor.keyboardFocusIndicatorColor.cgColor
        }
        return try #require(color)
    }
    #expect(try ring(in: .aqua) != ring(in: .darkAqua))
    view.appearance = NSAppearance(named: .aqua)
    fixture.controller.showsFocus = true
    #expect(view.layer?.borderColor == (try ring(in: .aqua)))

    view.appearance = NSAppearance(named: .darkAqua)
    #expect(view.layer?.borderColor == (try ring(in: .darkAqua)))

    view.appearance = NSAppearance(named: .aqua)
    #expect(view.layer?.borderColor == (try ring(in: .aqua)))
}
