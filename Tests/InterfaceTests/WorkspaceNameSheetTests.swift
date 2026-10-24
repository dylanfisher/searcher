import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

private let frame = Rect(x: 0, y: 0, width: 900, height: 600)

/// Two open workspaces at `/root` in one list, and a name sheet for the first that is never
/// shown, whose window is at `frame`.
@MainActor
private final class Fixture {
    let list = WorkspaceList()
    let workspace: Workspace
    let other: Workspace
    var closes = 0
    var beeps = 0

    init() {
        let service = ListingService(lister: StubLister(["/root": [file("a.txt")]])) { "Disk" }
        let make = {
            Workspace(
                tab: Tab(
                    pane: Pane(
                        location: Location(path: "/root"), service: service,
                        systemActions: StubSystemActions(), settings: untouchedSettings())))
        }
        workspace = make()
        other = make()
        list.add(other)
        list.add(workspace)
    }

    func sheet() -> WorkspaceNameSheet {
        let sheet = WorkspaceNameSheet(workspace: workspace, list: list, frame: { frame })
        sheet.onClose = { [weak self] in self?.closes += 1 }
        sheet.beep = { [weak self] in self?.beeps += 1 }
        return sheet
    }
}

@MainActor @Test func aNewNameSavesTheWorkspaceAndClosesTheSheet() {
    let fixture = Fixture()
    let sheet = fixture.sheet()
    #expect(sheet.alert.messageText == "Save this workspace as:")
    #expect(sheet.alert.buttons.map(\.title) == ["Save", Dialog.cancel])
    #expect(sheet.field.stringValue == "")

    sheet.field.stringValue = "Project 1"
    sheet.confirm()

    #expect(fixture.workspace.name == "Project 1")
    #expect(fixture.list.snapshots[fixture.workspace.id] == fixture.workspace.state(frame: frame))
    #expect(fixture.closes == 1)
}

@MainActor @Test func aTakenNameSaysWhichAndKeepsTheSheetUp() throws {
    let fixture = Fixture()
    try fixture.list.save(fixture.other, as: "Project 1", frame: frame)
    let sheet = fixture.sheet()

    sheet.field.stringValue = "project 1"
    sheet.confirm()

    #expect(fixture.workspace.name == nil)
    #expect(fixture.closes == 0)
    #expect(!sheet.messageLabel.isHidden)
    #expect(
        sheet.messageLabel.stringValue
            == "The name “Project 1” is already taken. Please choose a different name.")
}

@MainActor @Test func anEmptyNameBeepsAndKeepsTheSheetUp() {
    let fixture = Fixture()
    let sheet = fixture.sheet()

    sheet.field.stringValue = "  "
    sheet.confirm()

    #expect(fixture.beeps == 1)
    #expect(fixture.closes == 0)
    #expect(fixture.workspace.name == nil)
}

@MainActor @Test func renameStartsFromTheCurrentName() throws {
    let fixture = Fixture()
    try fixture.list.save(fixture.workspace, as: "Project 1", frame: frame)

    let sheet = fixture.sheet()

    #expect(sheet.alert.messageText == "Rename the workspace “Project 1”:")
    #expect(sheet.alert.buttons.map(\.title) == ["Rename", Dialog.cancel])
    #expect(sheet.field.stringValue == "Project 1")
    sheet.field.stringValue = "Project 2"
    sheet.confirm()
    #expect(fixture.workspace.name == "Project 2")
    #expect(fixture.list.snapshots[fixture.workspace.id]?.name == "Project 2")
}

@MainActor @Test func cancelLeavesTheNameAsItWas() {
    let fixture = Fixture()
    let sheet = fixture.sheet()

    sheet.field.stringValue = "Project 1"
    sheet.cancel()

    #expect(fixture.workspace.name == nil)
    #expect(fixture.closes == 1)
}

@MainActor @Test func savingBeforeTheSavedWorkspacesAreListedSaysWhy() {
    let fixture = Fixture()
    fixture.list.awaitsRestore = true
    let sheet = fixture.sheet()

    sheet.field.stringValue = "Project 1"
    sheet.confirm()

    #expect(fixture.workspace.name == nil)
    #expect(fixture.closes == 0)
    #expect(sheet.messageLabel.stringValue == WorkspaceList.NameRefusal.loading.description)
}
