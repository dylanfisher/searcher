import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A list of two open workspaces, "beta" and "Alpha", one closed saved workspace, "Gamma", and
/// an unnamed open one, which is the window's own; and a sidebar for that window that is never
/// shown, with the IDs it opens counted.
@MainActor
private final class Fixture {
    let list = WorkspaceList()
    let own: Workspace
    let alpha: Workspace
    let beta: Workspace
    let gamma: WorkspaceState
    var opened: [UUID] = []
    var escapes = 0
    let sidebar: WorkspaceSidebarViewController
    let window = KeyCatchingWindow()

    init() throws {
        let service = ListingService(lister: StubLister(["/root": [file("a.txt")]])) { "Disk" }
        let make = {
            Workspace(
                tab: Tab(
                    pane: Pane(
                        location: Location(path: "/root"), service: service,
                        systemActions: StubSystemActions(), settings: untouchedSettings())))
        }
        alpha = make()
        beta = make()
        own = make()
        for workspace in [alpha, beta, own] {
            list.add(workspace)
        }
        try list.name(beta, as: "beta")
        try list.name(alpha, as: "Alpha")
        gamma = WorkspaceState(
            id: UUID(), name: "Gamma", frame: Rect(x: 0, y: 0, width: 900, height: 600),
            tabs: alpha.tabs.map(\.state), selectedTab: 0, showsSidebar: false)
        try list.addSaved(gamma)
        sidebar = WorkspaceSidebarViewController(workspace: own, list: list)
        sidebar.open = { [weak self] id in self?.opened.append(id) }
        sidebar.onEscape = { [weak self] in self?.escapes += 1 }
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        window.contentView?.addSubview(sidebar.view)
        sidebar.view.layoutSubtreeIfNeeded()
    }

    var outline: NSOutlineView { sidebar.outlineView }

    /// Whether the outline's delegate draws `row` as a group row.
    func isGroupRow(_ row: Int) -> Bool {
        outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: row) as Any)
            == true
    }

    /// Each workspace row's cell, top to bottom, under the group row.
    var cells: [WorkspaceSidebarViewController.Cell] {
        get throws {
            try (0..<outline.numberOfRows).compactMap { row in
                guard outline.level(forRow: row) > 0 else { return nil }
                return try #require(
                    outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                        as? WorkspaceSidebarViewController.Cell)
            }
        }
    }

    var names: [String] {
        get throws { try cells.map { $0.textField?.stringValue ?? "" } }
    }

    /// The row showing `name`.
    func row(of name: String) throws -> Int {
        try #require(
            (0..<outline.numberOfRows).first { row in
                (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                    .textField?.stringValue == name
            })
    }
}

@MainActor @Test func theSidebarListsSavedNamesInOrderUnderAGroupAndMarksOpenOnes() throws {
    let fixture = try Fixture()

    #expect(fixture.outline.style == .sourceList)
    #expect(fixture.outline.level(forRow: 0) == 0 && fixture.isGroupRow(0))
    #expect(try fixture.names == ["Alpha", "beta", "Gamma"])
    #expect(try fixture.cells.map(\.showsOpen) == [true, true, false])
    #expect(
        try fixture.cells.map { $0.accessibilityLabel() ?? "" } == [
            "Alpha, open", "beta, open", "Gamma",
        ])
    #expect(fixture.outline.accessibilityLabel() == "Workspaces")
}

@MainActor @Test func returnOnARowOpensItsWorkspace() throws {
    let fixture = try Fixture()
    fixture.outline.selectRowIndexes([try fixture.row(of: "Gamma")], byExtendingSelection: false)

    fixture.outline.keyDown(with: try keyEvent("\r"))

    #expect(fixture.opened == [fixture.gamma.id])
    #expect(fixture.window.unhandledKeys.isEmpty)
}

@MainActor @Test func selectingARowByKeyDoesNotOpenIt() throws {
    let fixture = try Fixture()
    fixture.outline.selectRowIndexes([try fixture.row(of: "Alpha")], byExtendingSelection: false)

    fixture.outline.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))

    #expect(fixture.outline.selectedRow == (try fixture.row(of: "beta")))
    #expect(fixture.opened.isEmpty)
}

@MainActor @Test func escapeInTheSidebarHandsTheKeysBack() throws {
    let fixture = try Fixture()

    fixture.outline.keyDown(with: try keyEvent("\u{1B}"))

    #expect(fixture.escapes == 1)
    #expect(fixture.window.unhandledKeys.isEmpty)
}

@MainActor @Test func aRenameInTheModelUpdatesTheRow() throws {
    let fixture = try Fixture()

    try fixture.list.name(fixture.alpha, as: "Zeta")

    #expect(try fixture.names == ["beta", "Gamma", "Zeta"])
}

@MainActor @Test func namingTheWindowsWorkspaceListsAndSelectsIt() throws {
    let fixture = try Fixture()
    #expect(fixture.outline.selectedRow == -1)

    try fixture.list.name(fixture.own, as: "Delta")

    #expect(try fixture.names == ["Alpha", "beta", "Delta", "Gamma"])
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "Delta")))
}

@MainActor @Test func closingAndOpeningASavedWorkspaceMovesItsMark() throws {
    let fixture = try Fixture()
    let state = WorkspaceState(
        id: fixture.beta.id, name: "beta", frame: Rect(x: 0, y: 0, width: 900, height: 600),
        tabs: fixture.beta.tabs.map(\.state), selectedTab: 0, showsSidebar: false)

    fixture.list.windowClosed(fixture.beta, as: state)

    #expect(try fixture.cells.map(\.showsOpen) == [true, false, false])

    fixture.list.delete(fixture.gamma.id)

    #expect(try fixture.names == ["Alpha", "beta"])
}

@MainActor @Test func aRenameWhileTheSidebarHasTheKeysKeepsTheSelectionAndTheKeys() throws {
    let fixture = try Fixture()
    #expect(fixture.window.makeFirstResponder(fixture.outline))
    fixture.outline.selectRowIndexes([try fixture.row(of: "beta")], byExtendingSelection: false)

    try fixture.list.name(fixture.alpha, as: "Zeta")

    #expect(try fixture.names == ["beta", "Gamma", "Zeta"])
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "beta")))
    #expect(fixture.window.firstResponder === fixture.outline)
}

@MainActor @Test func deletingTheSelectedWorkspaceElsewhereSelectsTheWindowsOwnAndKeepsTheKeys()
    throws
{
    let fixture = try Fixture()
    try fixture.list.name(fixture.own, as: "Delta")
    #expect(fixture.window.makeFirstResponder(fixture.outline))
    fixture.outline.selectRowIndexes([try fixture.row(of: "Gamma")], byExtendingSelection: false)

    // As Delete Workspace in another window does.
    fixture.list.delete(fixture.gamma.id)

    #expect(try fixture.names == ["Alpha", "beta", "Delta"])
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "Delta")))
    #expect(fixture.window.firstResponder === fixture.outline)
}
