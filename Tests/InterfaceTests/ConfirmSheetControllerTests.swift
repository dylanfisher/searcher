import AppKit
import Foundation
import Testing

@testable import Browser
@testable import Interface

@MainActor
private final class Answers {
    var given: [Bool] = []
}

/// A confirm sheet for `request` that is never shown, logging its answers.
@MainActor
private func sheet(_ request: ConfirmRequest) -> (ConfirmSheetController, Answers) {
    let answers = Answers()
    let sheet = ConfirmSheetController(request: request) { answers.given.append($0) }
    return (sheet, answers)
}

private let copyTwo = ConfirmRequest.otherPane(.copy(["/a/one.txt", "/a/two.txt"], into: "/b"))
private let deleteOne = ConfirmRequest.deleteImmediately(
    ["/Volumes/Stick/a.txt"], operation: FileOperationQueue.ID(1))

/// Return or Esc as the sheet's window gets it.
@MainActor
private func press(_ key: String, in sheet: ConfirmSheetController) throws -> Bool {
    sheet.panel.performKeyEquivalent(with: try keyEvent(key))
}

@MainActor @Test func returnConfirmsAndEscCancelsTheConfirmSheet() throws {
    let (confirmed, yes) = sheet(copyTwo)
    let (cancelled, no) = sheet(copyTwo)

    #expect(try press("\r", in: confirmed))
    #expect(try press("\u{1B}", in: cancelled))

    #expect(yes.given == [true])
    #expect(no.given == [false])
}

@MainActor @Test func theConfirmSheetIsAnAlertWithTheConfirmButtonFirst() {
    let (sheet, _) = sheet(copyTwo)

    #expect(sheet.panel === sheet.alert.window)
    #expect(sheet.alert.buttons == [sheet.confirmButton, sheet.cancelButton])
    #expect(sheet.confirmButton.keyEquivalent == "\r")
    #expect(sheet.cancelButton.keyEquivalent == "\u{1B}")
    #expect(!sheet.confirmButton.hasDestructiveAction)
}

@MainActor @Test func theOtherPaneConfirmSaysWhatGoesWhere() {
    let (copy, _) = sheet(copyTwo)
    let (move, _) = sheet(.otherPane(.move(["/a/one.txt"], into: "/b/c")))

    #expect(copy.alert.messageText == "Copy 2 items to “b”?")
    #expect(copy.alert.informativeText.isEmpty)
    #expect(copy.confirmButton.title == "Copy")
    #expect(move.alert.messageText == "Move “one.txt” to “c”?")
    #expect(move.confirmButton.title == "Move")
}

@MainActor @Test func deleteImmediatelySaysItCantBeUndone() {
    let (sheet, answers) = sheet(deleteOne)

    #expect(sheet.alert.messageText == "Delete immediately? This can’t be undone.")
    #expect(sheet.alert.informativeText.contains("“a.txt”"))
    #expect(sheet.confirmButton.title == "Delete")
    #expect(sheet.confirmButton.hasDestructiveAction)

    sheet.cancelButton.performClick(nil)

    #expect(answers.given == [false])
}
