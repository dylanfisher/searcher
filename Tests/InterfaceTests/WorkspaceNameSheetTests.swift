import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

/// Two open workspaces at `/root` in one list, and a name sheet for the first that is never
/// shown.
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
        let sheet = WorkspaceNameSheet(workspace: workspace, list: list)
        sheet.onClose = { [weak self] in self?.closes += 1 }
        sheet.beep = { [weak self] in self?.beeps += 1 }
        return sheet
    }
}

@MainActor @Test func aNewNameNamesTheWorkspaceAndClosesTheSheet() {
    let fixture = Fixture()
    let sheet = fixture.sheet()
    #expect(sheet.alert.messageText == "Name this workspace:")
    #expect(sheet.alert.buttons.map(\.title) == ["Name", Dialog.cancel])
    #expect(sheet.field.stringValue == "")

    sheet.field.stringValue = "Project 1"
    sheet.confirm()

    #expect(fixture.workspace.name == "Project 1")
    #expect(fixture.closes == 1)
}

@MainActor @Test func aTakenNameSaysWhichAndKeepsTheSheetUp() throws {
    let fixture = Fixture()
    try fixture.list.name(fixture.other, as: "Project 1")
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
    try fixture.list.name(fixture.workspace, as: "Project 1")

    let sheet = fixture.sheet()

    #expect(sheet.alert.messageText == "Rename the workspace “Project 1”:")
    #expect(sheet.alert.buttons.map(\.title) == ["Rename", Dialog.cancel])
    #expect(sheet.field.stringValue == "Project 1")
}

@MainActor @Test func cancelLeavesTheNameAsItWas() {
    let fixture = Fixture()
    let sheet = fixture.sheet()

    sheet.field.stringValue = "Project 1"
    sheet.cancel()

    #expect(fixture.workspace.name == nil)
    #expect(fixture.closes == 1)
}

@MainActor @Test func nameBeforeTheSavedWorkspacesAreListedSaysWhy() {
    let fixture = Fixture()
    fixture.list.awaitsRestore = true
    let sheet = fixture.sheet()

    sheet.field.stringValue = "Project 1"
    sheet.confirm()

    #expect(fixture.workspace.name == nil)
    #expect(fixture.closes == 0)
    #expect(sheet.messageLabel.stringValue == WorkspaceList.NameRefusal.loading.description)
}
