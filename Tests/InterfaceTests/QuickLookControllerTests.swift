import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// Stands in for the system panel: records what the controller asks of it, and never shows.
@MainActor
private final class RecordingPanel: PreviewPanel {
    var currentPreviewItemIndex = 0
    private(set) var reloads = 0

    func reloadData() { reloads += 1 }
}

/// A pane at `/ql` in a view controller in a window that is never shown, its table first
/// responder, wired as the app wires it, with a Quick Look controller whose panel opening,
/// closing and beeps are only counted.
@MainActor
private final class Fixture {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    let pane: Pane
    let actions = StubSystemActions()
    let controller: PaneViewController
    let panel = RecordingPanel()
    private(set) var opens = 0
    private(set) var closes = 0
    private(set) var beeps = 0
    var panelIsOpen = false

    var quickLook: QuickLookController { controller.listingViewController.quickLook }
    var table: ListingTableView { controller.listingViewController.tableView }

    init(_ entries: [DirectoryEntry], sortedBy column: SortColumn = .name, ascending: Bool = true)
        async
    {
        pane = Pane(
            location: Location(path: "/ql"),
            service: ListingService(lister: StubLister(["/ql": entries])),
            systemActions: actions, settings: untouchedSettings(), sortedBy: column,
            ascending: ascending, isFocused: true)
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: ListingTableView(), monitorsFolders: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(controller.view)
        window.makeFirstResponder(table)
        quickLook.isPanelOpen = { [unowned self] in panelIsOpen }
        quickLook.openPanel = { [unowned self] in
            opens += 1
            panelIsOpen = true
        }
        quickLook.closePanel = { [unowned self] in
            closes += 1
            panelIsOpen = false
        }
        table.beep = { [unowned self] in beeps += 1 }
        await settle { self.pane.state.isLoaded }
    }

    func select(_ names: String..., cursor: String) {
        pane.select(Selection(Set(names.map(ExactName.init)), cursor: ExactName(cursor)))
    }

    /// The path of every item the controller hands the panel, in its order.
    var itemPaths: [String] {
        (0..<quickLook.itemCount).map { quickLook.url(at: $0).path }
    }

    /// The path of the item the panel shows.
    var currentPath: String { quickLook.url(at: panel.currentPreviewItemIndex).path }
}

private let space = " "
private let downArrow = functionKey(NSDownArrowFunctionKey)

@MainActor @Test func oneSelectedEntryGivesOneItemForItsURL() async {
    let fixture = await Fixture([file("a.png"), file("b.pdf"), folder("c")])
    fixture.select("b.pdf", cursor: "b.pdf")
    fixture.quickLook.begin(fixture.panel)

    #expect(fixture.quickLook.itemCount == 1)
    #expect(fixture.quickLook.url(at: 0) == URL(fileURLWithPath: "/ql/b.pdf", isDirectory: false))
    #expect(fixture.panel.currentPreviewItemIndex == 0)
}

@MainActor @Test func aSelectedFolderIsADirectoryURL() async {
    let fixture = await Fixture([file("a.png"), folder("c")])
    fixture.select("c", cursor: "c")
    fixture.quickLook.begin(fixture.panel)

    #expect(fixture.quickLook.url(at: 0) == URL(fileURLWithPath: "/ql/c", isDirectory: true))
}

@MainActor @Test func threeSelectedEntriesGiveThreeItemsInDisplayOrder() async {
    // Largest first: d, b, c, a.
    let fixture = await Fixture(
        [file("a", size: 1), file("b", size: 3), file("c", size: 2), file("d", size: 5)],
        sortedBy: .size, ascending: false)
    fixture.select("a", "b", "d", cursor: "b")
    fixture.quickLook.begin(fixture.panel)

    #expect(fixture.itemPaths == ["/ql/d", "/ql/b", "/ql/a"])
    // The panel opens on the cursor's entry.
    #expect(fixture.currentPath == "/ql/b")
}

/// From two selected entries with the cursor on the second, ↓ selects the third alone, so the
/// panel's current item moves from the second item to the first.
@MainActor @Test func downHandedToThePanelRunsSelectNextAndThePreviewFollows() async throws {
    let fixture = await Fixture([file("a.png"), file("b.pdf"), file("c.mp3")])
    fixture.select("a.png", "b.pdf", cursor: "b.pdf")
    fixture.quickLook.begin(fixture.panel)
    #expect(fixture.panel.currentPreviewItemIndex == 1)
    let reloads = fixture.panel.reloads

    let taken = fixture.quickLook.handle(try keyEvent(downArrow, modifiers: arrowFlags))

    #expect(taken)
    #expect(fixture.pane.selection == Selection([ExactName("c.mp3")], cursor: ExactName("c.mp3")))
    #expect(fixture.panel.reloads == reloads + 1)
    #expect(fixture.itemPaths == ["/ql/c.mp3"])
    #expect(fixture.panel.currentPreviewItemIndex == 0)
    #expect(fixture.currentPath == "/ql/c.mp3")
}

/// The cursor can sit on a row that isn't selected, after a Cmd-click deselects it. The panel
/// opens on the first item then. The cursor is between two selected rows, so counting the
/// selected rows before it would give the second item.
@MainActor @Test func withTheCursorOnAnUnselectedRowThePanelOpensOnTheFirstItem() async {
    let fixture = await Fixture([file("a"), file("b"), file("c"), file("d"), file("e")])
    fixture.pane.select(
        Selection([ExactName("b"), ExactName("d"), ExactName("e")], cursor: ExactName("c")))
    fixture.quickLook.begin(fixture.panel)

    #expect(fixture.itemPaths == ["/ql/b", "/ql/d", "/ql/e"])
    #expect(fixture.panel.currentPreviewItemIndex == 0)
}

/// A download's folder sends a patch every 0.1 s. One that changes an entry the panel doesn't
/// show leaves the preview alone.
@MainActor @Test func aPatchToAnUnselectedEntryDoesNotReloadThePanel() async {
    let fixture = await Fixture([file("a.png"), file("b.pdf"), file("c.mp3")])
    fixture.select("a.png", cursor: "a.png")
    fixture.quickLook.begin(fixture.panel)
    let reloads = fixture.panel.reloads
    let version = fixture.pane.stateVersion

    fixture.pane.apply(.patches([.update(file("c.mp3", size: 9))]), at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }

    #expect(fixture.panel.reloads == reloads)
    #expect(fixture.currentPath == "/ql/a.png")
}

/// Renaming the entry shown takes it out of the selection, so the panel reloads once, on the
/// entry still selected.
@MainActor @Test func aPatchRenamingTheShownEntryReloadsThePanelOnce() async {
    let fixture = await Fixture([file("a.png"), file("b.pdf"), file("c.mp3")])
    fixture.select("a.png", "c.mp3", cursor: "a.png")
    fixture.quickLook.begin(fixture.panel)
    let reloads = fixture.panel.reloads
    let version = fixture.pane.stateVersion

    fixture.pane.apply(
        .patches([.remove(name: "a.png"), .update(file("a-renamed.png"))]),
        at: fixture.pane.location)
    await settle { fixture.pane.stateVersion != version }

    #expect(fixture.panel.reloads == reloads + 1)
    #expect(fixture.itemPaths == ["/ql/c.mp3"])
    #expect(fixture.currentPath == "/ql/c.mp3")
}

/// The items of a panel that closed don't outlive it: opening it again on a selection still
/// settling shows nothing from the folder before.
@MainActor @Test func endingControlDropsTheItems() async {
    let fixture = await Fixture([file("a.png"), file("b.pdf")])
    fixture.select("a.png", "b.pdf", cursor: "a.png")
    fixture.quickLook.begin(fixture.panel)
    #expect(fixture.quickLook.itemCount == 2)

    fixture.quickLook.end()

    #expect(fixture.quickLook.itemCount == 0)
}

@MainActor @Test func aKeyNoCommandTakesIsLeftToThePanel() async throws {
    let fixture = await Fixture([file("a.png"), file("b.pdf")])
    fixture.select("a.png", cursor: "a.png")
    fixture.quickLook.begin(fixture.panel)

    // Escape closes the panel, which handles it itself.
    #expect(!fixture.quickLook.handle(try keyEvent("\u{1b}")))
    #expect(fixture.pane.selection == Selection([ExactName("a.png")], cursor: ExactName("a.png")))
}

@MainActor @Test func spaceWithNothingSelectedBeeps() async throws {
    let fixture = await Fixture([file("a.png")])

    fixture.table.keyDown(with: try keyEvent(space))

    #expect(fixture.beeps == 1)
    #expect(fixture.opens == 0)
}

@MainActor @Test func spaceOpensThePanelAndSpaceInThePanelClosesIt() async throws {
    let fixture = await Fixture([file("a.png")])
    fixture.select("a.png", cursor: "a.png")

    fixture.table.keyDown(with: try keyEvent(space))
    #expect(fixture.opens == 1)
    fixture.quickLook.begin(fixture.panel)
    #expect(fixture.quickLook.handle(try keyEvent(space)))

    #expect(fixture.closes == 1)
    #expect(fixture.beeps == 0)
}

@MainActor @Test func theControllerNeverOpensAFile() async throws {
    let fixture = await Fixture([file("a.png"), folder("b"), file("c.pdf")])
    fixture.select("a.png", "b", cursor: "a.png")

    fixture.table.keyDown(with: try keyEvent(space))
    fixture.quickLook.begin(fixture.panel)
    _ = fixture.itemPaths
    _ = fixture.quickLook.handle(try keyEvent(downArrow, modifiers: arrowFlags))
    _ = fixture.quickLook.handle(try keyEvent(space))
    fixture.quickLook.end()

    #expect(fixture.actions.openedFiles.isEmpty)
    #expect(fixture.actions.openedURLs.isEmpty)
    #expect(fixture.pane.location == Location(path: "/ql"))
}

@MainActor @Test func selectAllGivesEveryRowInOrder() async {
    let names = (0..<2_000).map { String(format: "e%04d", $0) }
    let fixture = await Fixture(names.map { file($0) })
    fixture.pane.selectAll()
    await settle { fixture.pane.selection.isSettled }
    fixture.quickLook.begin(fixture.panel)

    #expect(fixture.quickLook.itemCount == 2_000)
    #expect(fixture.quickLook.url(at: 0).lastPathComponent == "e0000")
    #expect(fixture.quickLook.url(at: 1_999).lastPathComponent == "e1999")
}

/// Cmd-A while a patch runs leaves a provisional selection that knows only the rows near the
/// cursor. The panel waits for it to settle off the main thread rather than show part of it.
@MainActor @Test func aProvisionalSelectionIsPreviewedOnceItSettles() async throws {
    let names = (0..<100).map { String(format: "n%03d", $0) }
    let fixture = await Fixture(names.map { file($0) })
    let pane = fixture.pane
    let held = DispatchQueue(label: "held settles")
    held.suspend()
    pane.settleQueue = held
    let version = pane.stateVersion

    pane.apply(.patches([.update(file("a-new"))]), at: pane.location)
    pane.selectAll()
    await settle { pane.stateVersion != version }
    #expect(pane.selection.isProvisional)
    fixture.quickLook.begin(fixture.panel)
    #expect(fixture.quickLook.itemCount == 0)

    held.resume()
    await settle { pane.selection.isSettled }
    #expect(fixture.quickLook.itemCount == 100)
    #expect(!fixture.itemPaths.contains("/ql/a-new"))
}

@MainActor @Test func endingControlLeavesThePanelAlone() async throws {
    let fixture = await Fixture([file("a.png"), file("b.pdf")])
    fixture.select("a.png", cursor: "a.png")
    fixture.quickLook.begin(fixture.panel)
    fixture.quickLook.end()
    let reloads = fixture.panel.reloads

    fixture.pane.moveSelection(by: 1)

    #expect(fixture.panel.reloads == reloads)
}

/// A key the panel hands back runs its command through the table, which ends the query, as the
/// same key in the list does.
@MainActor @Test func aCommandFromThePanelEndsTheTypeSelectQuery() async throws {
    let fixture = await Fixture([file("a.png"), file("b.png"), file("c.png")])
    fixture.table.keyDown(with: try keyEvent("b"))
    #expect(fixture.table.typeSelect.isTyping)

    #expect(fixture.quickLook.handle(try keyEvent(downArrow, modifiers: arrowFlags)))

    #expect(!fixture.table.typeSelect.isTyping)
}

/// After the window moves its keys elsewhere, such as to another pane, a key the panel hands back
/// runs nothing: the table's pane may no longer be the focused one.
@MainActor @Test func aKeyFromThePanelIsDroppedOnceTheTableLostTheKeys() async throws {
    let fixture = await Fixture([file("a.png"), file("b.pdf"), file("c.mp3")])
    fixture.select("a.png", cursor: "a.png")
    fixture.quickLook.begin(fixture.panel)
    let other = NSTextField(string: "")
    fixture.window.contentView?.addSubview(other)
    #expect(fixture.window.makeFirstResponder(other))

    #expect(fixture.quickLook.handle(try keyEvent(downArrow, modifiers: arrowFlags)))

    #expect(fixture.pane.selection == Selection([ExactName("a.png")], cursor: ExactName("a.png")))
}
