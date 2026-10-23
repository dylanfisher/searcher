import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A loaded pane at `/root` in a view controller inside a window that is never shown, with the
/// table first responder.
@MainActor
private struct Fixture {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    let pane: Pane
    let controller: PaneViewController
    let table = ListingTableView()

    init() async {
        window.isReleasedWhenClosed = false
        pane = Pane(
            location: Location(path: "/root"),
            service: ListingService(
                lister: StubLister([
                    "/root": [
                        file("Report.pdf"), file("readme"), folder("PORTFOLIO"), folder("docs"),
                    ],
                    "/root/docs": [file("inside.txt")],
                ]),
                rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true)
        controller = PaneViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            tableView: table, monitorsFolders: false)
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        window.contentView?.addSubview(controller.view)
        let pane = pane
        await settle { pane.state.isLoaded }
        window.makeFirstResponder(table)
    }

    var filterBar: FilterBarView { controller.filterBar }

    /// Presses Cmd-F in the list and returns the field editor it focused.
    func openFilter() throws -> NSTextView {
        table.keyDown(with: try keyEvent("f", modifiers: .command))
        return try editor()
    }

    func editor() throws -> NSTextView {
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.isFieldEditor)
        #expect(editor.delegate === filterBar.field)
        return editor
    }

    func type(_ text: String, into editor: NSTextView) {
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    var rows: [String] {
        guard let listing = pane.state.listing else { return [] }
        return (0..<listing.count).map { listing[$0].name }
    }
}

@MainActor @Test func cmdFShowsTheFilterAndFocusesItsField() async throws {
    let fixture = await Fixture()
    #expect(fixture.filterBar.isHidden)

    _ = try fixture.openFilter()

    #expect(!fixture.filterBar.isHidden)
}

@MainActor @Test func typingInTheFieldNarrowsTheList() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()

    fixture.type("port", into: editor)

    #expect(fixture.pane.filter.text == "port")
    await settle { fixture.rows == ["PORTFOLIO", "Report.pdf"] }
    await settle { rowNames(fixture.table) == ["PORTFOLIO", "Report.pdf"] }
}

@MainActor @Test func cmdAInTheFieldSelectsItsTextNotFiles() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()
    fixture.type("port", into: editor)
    await settle { fixture.rows.count == 2 }

    // The Edit menu's Select All goes up the responder chain from the field editor.
    #expect(editor.tryToPerform(#selector(NSResponder.selectAll(_:)), with: nil))

    #expect(editor.selectedRange() == NSRange(location: 0, length: 4))
    let first = ExactName("PORTFOLIO")
    #expect(fixture.pane.selection == Selection([first], cursor: first))
}

@MainActor @Test func upAndDownInTheFieldMoveTheListSelection() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()
    fixture.type("port", into: editor)
    await settle { fixture.rows.count == 2 }
    let down = try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags)
    let up = try keyEvent(functionKey(NSUpArrowFunctionKey), modifiers: arrowFlags)

    editor.keyDown(with: down)
    #expect(fixture.pane.selection.cursor == ExactName("Report.pdf"))
    editor.keyDown(with: up)
    #expect(fixture.pane.selection.cursor == ExactName("PORTFOLIO"))

    // The keys moved the list; the field keeps focus and its text.
    #expect(fixture.window.firstResponder === editor)
    #expect(fixture.filterBar.field.stringValue == "port")
}

@MainActor @Test func escapeClearsTheFilterAndFocusesTheList() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()
    fixture.type("port", into: editor)
    await settle { fixture.rows.count == 2 }

    editor.keyDown(with: try keyEvent("\u{1B}"))

    #expect(fixture.pane.filter.isEmpty)
    #expect(fixture.filterBar.isHidden)
    #expect(fixture.filterBar.field.stringValue.isEmpty)
    #expect(fixture.window.firstResponder === fixture.table)
    await settle { fixture.rows.count == 4 }
}

@MainActor @Test func anEmptyResultSaysNoItemsMatchWithTheQuery() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()

    fixture.type("zzz", into: editor)
    await settle { fixture.pane.state.listing?.filter == NameFilter("zzz") }

    #expect(!fixture.controller.messageLabel.isHidden)
    #expect(fixture.controller.messageLabel.stringValue.contains("No items match"))
    #expect(fixture.controller.messageLabel.stringValue.contains("zzz"))

    editor.deleteBackward(nil)
    editor.deleteBackward(nil)
    editor.deleteBackward(nil)
    await settle { fixture.pane.state.listing?.filter.isEmpty == true }
    #expect(fixture.controller.messageLabel.isHidden)
}

@MainActor @Test func noItemsMatchShowsTheQueryAsTyped() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()
    fixture.type("zzz", into: editor)
    await settle { !fixture.controller.messageLabel.isHidden }

    // The same fold, so the rows don't change, but the message follows the text.
    editor.selectAll(nil)
    fixture.type("ZZZ", into: editor)

    #expect(fixture.controller.messageLabel.stringValue.contains("“ZZZ”"))
}

@MainActor @Test func cmdFInTheFieldSelectsItsText() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()
    fixture.type("port", into: editor)
    editor.setSelectedRange(NSRange(location: 4, length: 0))

    #expect(fixture.window.performKeyEquivalent(with: try keyEvent("f", modifiers: .command)))

    #expect(editor.selectedRange() == NSRange(location: 0, length: 4))
    #expect(fixture.window.firstResponder === editor)
}

@MainActor @Test func cmdFInTheListLeavesTheKeyToTheMenu() async throws {
    let fixture = await Fixture()
    _ = try fixture.openFilter()
    fixture.window.makeFirstResponder(fixture.table)

    #expect(!fixture.window.performKeyEquivalent(with: try keyEvent("f", modifiers: .command)))
}

@MainActor @Test func lettersInTheListStillTypeSelectWhileTheFilterIsOpen() async throws {
    let fixture = await Fixture()
    _ = try fixture.openFilter()
    fixture.window.makeFirstResponder(fixture.table)

    fixture.table.keyDown(with: try keyEvent("r"))

    #expect(fixture.pane.selection.cursor == ExactName("readme"))
    #expect(fixture.pane.filter.isEmpty)
}

@MainActor @Test func navigatingHidesTheFilterAndFocusesTheList() async throws {
    let fixture = await Fixture()
    let editor = try fixture.openFilter()
    fixture.type("doc", into: editor)
    await settle { fixture.rows == ["docs"] }

    fixture.pane.navigate(to: Location(path: "/root/docs"))

    #expect(fixture.filterBar.isHidden)
    #expect(fixture.filterBar.field.stringValue.isEmpty)
    #expect(fixture.window.firstResponder === fixture.table)
}
