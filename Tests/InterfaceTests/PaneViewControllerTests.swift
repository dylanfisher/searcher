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

    func openFile(_ url: URL) { openedFiles.append(url) }
    func openURL(_ url: URL) { openedURLs.append(url) }
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

    init(lister: any Lister = StubLister(Fixture.folders), monitors: Bool = false) {
        pane = Pane(
            location: Location(path: "/root"), service: ListingService(lister: lister),
            systemActions: actions, isFocused: true)
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

private let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

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
    fixture.pane.select([ExactName("docs")])
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

    #expect(fixture.pane.selection == [ExactName("b.txt")])
    #expect(fixture.table.selectedRowIndexes == [1])
}

@MainActor @Test func cmdDownOpensTheSelectedFolderAndCmdUpGoesBack() async throws {
    let fixture = Fixture()
    await settle { fixture.pane.state.isLoaded }
    fixture.table.selectRowIndexes([2], byExtendingSelection: false)
    #expect(fixture.pane.selection == [ExactName("docs")])

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

@MainActor @Test func fileCreatedInThePanesFolderShowsUp() async throws {
    let folder = try TemporaryFolder("PaneViewControllerTests")
    let url = folder.url
    try await Task.detached { try Data().write(to: url.appending(path: "old.txt")) }.value
    let pane = Pane(
        location: Location(path: url.path), service: ListingService(),
        systemActions: StubSystemActions(), isFocused: true)
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
