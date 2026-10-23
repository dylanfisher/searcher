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

/// Return or Esc as the sheet's window gets it.
@MainActor
private func press(_ key: String, in sheet: ConfirmSheetController) throws -> Bool {
    sheet.panel.contentView?.layoutSubtreeIfNeeded()
    return sheet.panel.performKeyEquivalent(with: try keyEvent(key))
}

@MainActor @Test func returnConfirmsAndEscCancelsTheConfirmSheet() throws {
    let (confirmed, yes) = sheet(copyTwo)
    let (cancelled, no) = sheet(copyTwo)

    #expect(try press("\r", in: confirmed))
    #expect(try press("\u{1B}", in: cancelled))

    #expect(yes.given == [true])
    #expect(no.given == [false])
}

@MainActor @Test func theOtherPaneConfirmSaysWhatGoesWhere() {
    let (copy, _) = sheet(copyTwo)
    let (move, _) = sheet(.otherPane(.move(["/a/one.txt"], into: "/b/c")))

    #expect(copy.messageLabel.stringValue == "Copy 2 items to “b”?")
    #expect(copy.confirmButton.title == "Copy")
    #expect(move.messageLabel.stringValue == "Move “one.txt” to “c”?")
    #expect(move.confirmButton.title == "Move")
}

@MainActor @Test func deleteImmediatelySaysItCantBeUndone() {
    let (sheet, answers) = sheet(
        .deleteImmediately(["/Volumes/Stick/a.txt"], operation: FileOperationQueue.ID(1)))

    #expect(sheet.messageLabel.stringValue == "Delete immediately? This can’t be undone.")
    #expect(sheet.detailLabel.stringValue.contains("“a.txt”"))
    #expect(sheet.confirmButton.title == "Delete")

    sheet.cancelButton.performClick(nil)

    #expect(answers.given == [false])
}
