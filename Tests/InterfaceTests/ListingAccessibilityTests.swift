import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// Dates in UTC and English, as in `ListingViewControllerTests`.
@MainActor
private let formatter = EntryCellFormatter(
    locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)

/// One accessibility notification the filter field would have posted.
private struct Post {
    let notification: NSAccessibility.Notification
    let userInfo: [NSAccessibility.NotificationUserInfoKey: Any]?

    var announcement: String? { userInfo?[.announcement] as? String }
}

/// A pane at `/root` in a view controller inside a window that is never shown, with the table
/// first responder. The filter field's notifications are recorded rather than posted. The
/// table's own selection changes, which `NSTableView` reports to VoiceOver itself, are counted.
@MainActor
private final class Fixture {
    let window = testWindow(size: NSSize(width: 800, height: 400))
    let pane: Pane
    let controller: PaneViewController
    let table = ListingTableView()
    private(set) var posts: [Post] = []
    /// How many times the table's selection changed; `NSTableView` posts one
    /// `selectedRowsChanged` with each.
    private(set) var selectionChanges = 0

    /// Loaded with `entries`.
    convenience init(_ entries: [DirectoryEntry]) async {
        await self.init(lister: StubLister(["/root": entries]))
        let pane = pane
        await settle { pane.state.isLoaded }
    }

    init(lister: any Lister) async {
        window.isReleasedWhenClosed = false
        pane = Pane(
            location: Location(path: "/root"),
            service: ListingService(lister: lister, rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() },
            formatter: formatter, tableView: table, monitorsFolders: false)
        controller.filterBar.postAccessibility = { [unowned self] _, notification, userInfo in
            posts.append(Post(notification: notification, userInfo: userInfo))
        }
        // Left registered: it holds the fixture weakly, and the table goes with the fixture.
        _ = NotificationCenter.default.addObserver(
            forName: NSTableView.selectionDidChangeNotification, object: table, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.selectionChanges += 1 }
        }
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView?.addSubview(controller.view)
        window.makeFirstResponder(table)
    }

    /// Opens the filter with Cmd-F and returns the field editor it focused.
    func openFilter() throws -> NSTextView {
        table.keyDown(with: try keyEvent("f", modifiers: .command))
        return try #require(window.firstResponder as? NSTextView)
    }

    func type(_ text: String, into editor: NSTextView) {
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    var announcements: [String] {
        posts.filter { $0.notification == .announcementRequested }.compactMap(\.announcement)
    }

    /// The label of the row view the table shows for `row`, once the table has laid it out.
    func rowLabel(_ row: Int) throws -> String? {
        window.contentView?.layoutSubtreeIfNeeded()
        table.layoutSubtreeIfNeeded()
        let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: false))
        return rowView.accessibilityLabel()
    }

    func press(_ key: Int, _ modifiers: NSEvent.ModifierFlags) throws {
        table.keyDown(with: try keyEvent(functionKey(key), modifiers: arrowFlags.union(modifiers)))
    }

    /// Presses Home or End, which carry the function flag and no arrow flags.
    func pressHomeOrEnd(_ key: Int) throws {
        table.keyDown(with: try keyEvent(functionKey(key), modifiers: .function))
    }
}

private func kindText(_ type: DirectoryEntry.FileType, _ pathExtension: Substring) async -> String {
    await Task.detached { EntryKind(type, pathExtension: pathExtension).text }.value
}

/// "modified Sep 13, 2020 at 12:26 PM", from the formatter the date cells use: its text puts a
/// narrow no-break space before "PM".
@MainActor
private var modified: String {
    "modified \(formatter.date(testDate))"
}

// MARK: Row labels

@MainActor @Test func aRowsLabelReadsItsNameKindSizeAndDate() async throws {
    let fixture = await Fixture([file("Report.pdf", size: 2_000_000)])
    let kind = await kindText(.regular, "pdf")

    #expect(try fixture.rowLabel(0) == "Report.pdf, \(kind), 2 MB, \(modified)")
}

@MainActor @Test func aFolderLabelLeavesOutTheMissingSize() async throws {
    let fixture = await Fixture([folder("docs")])
    let kind = await kindText(.directory, "")

    #expect(try fixture.rowLabel(0) == "docs, \(kind), \(modified)")
}

/// The row label says it once, so the badge isn't a second element saying it again.
@MainActor @Test func aNotDownloadedEntrySaysSoOnceInItsRowLabel() async throws {
    let entry = DirectoryEntry(
        name: "Movie.mov", type: .regular, size: 4_000_000, modified: testDate, isHidden: false,
        isDataless: true)
    let fixture = await Fixture([entry])
    let kind = await kindText(.regular, "mov")

    #expect(try fixture.rowLabel(0) == "Movie.mov, \(kind), 4 MB, \(modified), Not downloaded")
    let list = fixture.controller.listingViewController
    let cell = try #require(
        list.tableView(fixture.table, viewFor: fixture.table.tableColumns[0], row: 0)
            as? NSTableCellView)
    let badge = try #require(
        cell.subviews.first { $0.identifier == ListingViewController.notDownloadedBadgeIdentifier })
    #expect(!badge.isHidden)
    #expect(!badge.isAccessibilityElement())
}

@MainActor @Test func rowsRefreshedInPlaceTakeTheirNewEntrysLabel() async throws {
    let fixture = await Fixture([file("a.txt", size: 1_000), file("b.txt", size: 2_000)])
    #expect(try fixture.rowLabel(0)?.hasPrefix("a.txt, ") == true)

    fixture.pane.setSort(.name, ascending: false)
    await settle { fixture.pane.state.listing?[0].name == "b.txt" }

    #expect(try fixture.rowLabel(0)?.hasPrefix("b.txt, ") == true)
}

@MainActor @Test func aPatchThatChangesASizeUpdatesTheRowsLabel() async throws {
    let fixture = await Fixture([file("Report.pdf", size: 1_000)])
    let pane = fixture.pane
    #expect(try fixture.rowLabel(0)?.contains(", 1 KB, ") == true)

    pane.apply(.patches([.update(file("Report.pdf", size: 2_000_000))]), at: pane.location)
    await settle { pane.state.listing?[0].size == 2_000_000 }

    #expect(try fixture.rowLabel(0)?.contains(", 2 MB, ") == true)
}

// MARK: Selection announcements

/// Each move changes the table's selection once, and `NSTableView` posts one
/// `selectedRowsChanged` for each change, so VoiceOver hears each move once.
@MainActor @Test func endCtrlShiftDownAndATypeSelectEachChangeTheTableSelectionOnce()
    async throws
{
    let names = (0..<30).map { String(format: "n%02d", $0) }
    let fixture = await Fixture(names.map { file($0) })
    let start = fixture.selectionChanges

    try fixture.pressHomeOrEnd(NSEndFunctionKey)
    #expect(fixture.pane.selection.cursor == ExactName("n29"))
    #expect(fixture.selectionChanges == start + 1)

    try fixture.pressHomeOrEnd(NSHomeFunctionKey)
    try fixture.press(NSDownArrowFunctionKey, [.control, .shift])
    #expect(fixture.pane.selection.cursor == ExactName("n10"))
    #expect(fixture.selectionChanges == start + 3)

    fixture.table.keyDown(with: try keyEvent("n"))
    fixture.table.keyDown(with: try keyEvent("2"))
    #expect(fixture.pane.selection.cursor == ExactName("n20"))
    #expect(fixture.selectionChanges == start + 5)
}

@MainActor @Test func aKeyThatLeavesTheSelectionWhereItIsChangesNothing() async throws {
    let fixture = await Fixture([file("a"), file("b")])
    try fixture.pressHomeOrEnd(NSEndFunctionKey)
    let changes = fixture.selectionChanges

    try fixture.pressHomeOrEnd(NSEndFunctionKey)

    #expect(fixture.selectionChanges == changes)
}

/// Cmd-A while a patch runs leaves a provisional selection showing only the rows near the cursor.
/// Settling it selects the rest, a real change to the selected rows, so the table reports that
/// change too.
@MainActor @Test func aProvisionalSelectionChangesTheTableAgainWhenItSettles() async throws {
    let names = (0..<100).map { String(format: "n%03d", $0) }
    let fixture = await Fixture(names.map { file($0) })
    let pane = fixture.pane
    let held = heldQueue("held settles")
    pane.settleQueue = held
    let version = pane.stateVersion

    pane.apply(.patches([.update(file("a-new"))]), at: pane.location)
    fixture.table.keyDown(with: try keyEvent("a", modifiers: .command))
    await settle { pane.stateVersion != version }
    #expect(pane.selection.isProvisional)
    let provisional = fixture.selectionChanges

    held.resume()
    await settle { pane.selection.isSettled }
    #expect(fixture.table.selectedRowIndexes.count == 100)
    #expect(fixture.selectionChanges == provisional + 1)
}

// MARK: Path bar and filter field

@MainActor @Test func pathBarSegmentsAreButtonsNamedForTheirFolders() {
    let bar = PathBarView()
    bar.frame = NSRect(x: 0, y: 0, width: 800, height: PathBarView.height)
    bar.show(Location(path: "/Users/dylan").ancestors, rootVolumeName: "Work Disk")

    #expect(bar.isAccessibilityElement())
    #expect(bar.accessibilityRole() == .group)
    #expect(bar.accessibilityLabel() == PathBarView.label)
    // What VoiceOver finds in the bar: a button per folder, and not the "›" drawn between them.
    // A control's element is its cell.
    let children = (bar.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityProtocol }
    #expect(children.map { $0.accessibilityRole() } == [.button, .button, .button])
    #expect(children.map { $0.accessibilityTitle() } == ["Work Disk", "Users", "dylan"])
}

@MainActor @Test func theFilterFieldIsLabeled() async throws {
    let fixture = await Fixture([file("a")])

    #expect(fixture.controller.filterBar.field.accessibilityLabel() == FilterBarView.fieldLabel)
}

@MainActor @Test func aFilterAnnouncesItsCountOnceTheRowsLandNotPerKey() async throws {
    let fixture = await Fixture([
        file("Report.pdf"), file("readme"), folder("PORTFOLIO"), folder("docs"),
    ])
    let editor = try fixture.openFilter()

    for letter in ["p", "o", "r", "t"] {
        fixture.type(letter, into: editor)
    }
    #expect(fixture.announcements.isEmpty)
    await settle { fixture.pane.state.listing?.filter == NameFilter("port") }

    #expect(fixture.announcements == ["2 items"])

    fixture.type("f", into: editor)
    await settle { fixture.pane.state.listing?.filter == NameFilter("portf") }
    #expect(fixture.announcements == ["2 items", "1 item"])

    fixture.type("z", into: editor)
    await settle { fixture.pane.state.listing?.filter == NameFilter("portfz") }
    #expect(fixture.announcements == ["2 items", "1 item", FilterBarView.noMatchMessage("portfz")])
}

@MainActor @Test func aPatchOrReloadUnderTheSameFilterDoesNotAnnounceAgain() async throws {
    let fixture = await Fixture([file("Report.pdf"), folder("PORTFOLIO"), file("readme")])
    let pane = fixture.pane
    fixture.type("port", into: try fixture.openFilter())
    await settle { pane.state.listing?.filter == NameFilter("port") }
    #expect(fixture.announcements == ["2 items"])

    var version = pane.stateVersion
    pane.apply(.patches([.update(file("Report.pdf", size: 5_000))]), at: pane.location)
    await settle { pane.stateVersion != version && pane.state.isLoaded }
    version = pane.stateVersion
    pane.reload()
    await settle { pane.stateVersion != version && pane.state.isLoaded }

    #expect(fixture.announcements == ["2 items"])
}

/// The same query typed in a new folder before its listing lands is that folder's first result,
/// so it is announced even though it matches the last folder's.
@MainActor @Test func theSameQueryInANewFolderIsAnnouncedThere() async throws {
    let lister = GatedLister([
        "/root": .batches([[file("Report.pdf"), folder("docs")]]),
        "/root/docs": .batches([[file("port-a"), file("port-b"), file("other")]]),
    ])
    lister.release("/root")
    let fixture = await Fixture(lister: lister)
    let pane = fixture.pane
    await settle { pane.state.isLoaded }
    fixture.type("port", into: try fixture.openFilter())
    await settle { pane.state.listing?.filter == NameFilter("port") }
    #expect(fixture.announcements == ["1 item"])

    pane.navigate(to: Location(path: "/root/docs"))
    fixture.type("port", into: try fixture.openFilter())
    lister.release("/root/docs")
    await settle { pane.state.isLoaded && pane.state.listing?.filter == NameFilter("port") }

    #expect(fixture.announcements == ["1 item", "2 items"])
}
