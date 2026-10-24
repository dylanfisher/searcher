import AppKit
import Foundation
import Testing

@testable import Browser
@testable import Interface

@MainActor
private final class Answers {
    var given: [ConflictResolution?] = []
}

private let modified = Date(timeIntervalSince1970: 1_600_000_000)

private func request(remaining: Int) -> ConflictRequest {
    ConflictRequest(
        operation: FileOperationQueue.ID(4),
        source: ConflictRequest.Item(
            path: "/src/report.pdf", isFolder: false, bytes: 2_000_000, modified: modified),
        existing: ConflictRequest.Item(
            path: "/dst/report.pdf", isFolder: false, bytes: 1_000,
            modified: modified.addingTimeInterval(-86_400)),
        remaining: remaining)
}

/// A conflict sheet that is never shown, logging its answers.
@MainActor
private func sheet(remaining: Int = 2) -> (ConflictSheetController, Answers) {
    let answers = Answers()
    let sheet = ConflictSheetController(request: request(remaining: remaining)) {
        answers.given.append($0)
    }
    return (sheet, answers)
}

@MainActor @Test func theConflictSheetReturnsTheChoiceWithTheApplyToAllFlag() {
    let (sheet, answers) = sheet()

    sheet.applyToAllBox.state = .on
    sheet.replaceButton.performClick(nil)

    #expect(answers.given == [ConflictResolution(choice: .replace, appliesToAll: true)])
}

@MainActor @Test func skipAndKeepBothAnswerForThisItemOnly() {
    let (skipSheet, skipped) = sheet()
    let (keepSheet, kept) = sheet()

    skipSheet.skipButton.performClick(nil)
    keepSheet.keepBothButton.performClick(nil)

    #expect(skipped.given == [ConflictResolution(choice: .skip, appliesToAll: false)])
    #expect(kept.given == [ConflictResolution(choice: .keepBoth, appliesToAll: false)])
}

@MainActor @Test func cancelAnswersNothing() {
    let (sheet, answers) = sheet()

    sheet.cancelButton.performClick(nil)

    #expect(answers.given == [nil])
}

@MainActor @Test func theSheetShowsBothItemsSizeAndDate() {
    let (sheet, _) = sheet()
    let formatter = EntryCellFormatter()
    let lines = sheet.alert.informativeText.split(separator: "\n").map(String.init)

    #expect(sheet.alert.messageText.contains("“report.pdf”"))
    #expect(sheet.alert.messageText.contains("“dst”"))
    #expect(lines.count == 2)
    #expect(lines[0].contains(formatter.bytes(1_000)))
    #expect(lines[0].contains(formatter.date(modified.addingTimeInterval(-86_400))))
    #expect(lines[1].contains(formatter.bytes(2_000_000)))
    #expect(lines[1].contains(formatter.date(modified)))
}

@MainActor @Test func applyToAllShowsOnlyWhenMoreConflictsFollow() {
    let (last, _) = sheet(remaining: 0)
    let (more, _) = sheet(remaining: 3)

    #expect(!last.alert.showsSuppressionButton)
    #expect(more.alert.showsSuppressionButton)
    #expect(more.applyToAllBox === more.alert.suppressionButton)
    #expect(more.applyToAllBox.title.contains("3"))
}

@MainActor @Test func theConflictSheetIsAnAlertWithKeepBothAsTheDefault() {
    let (sheet, _) = sheet()

    #expect(sheet.panel === sheet.alert.window)
    #expect(
        sheet.alert.buttons == [
            sheet.keepBothButton, sheet.replaceButton, sheet.skipButton, sheet.cancelButton,
        ])
    #expect(sheet.keepBothButton.keyEquivalent == "\r")
    #expect(sheet.cancelButton.keyEquivalent == "\u{1B}")
    #expect(sheet.replaceButton.hasDestructiveAction)
}

@MainActor @Test func returnKeepsBothAndEscCancels() throws {
    let (kept, keptAnswers) = sheet()
    let (cancelled, cancelledAnswers) = sheet()

    #expect(kept.panel.performKeyEquivalent(with: try keyEvent("\r")))
    #expect(cancelled.panel.performKeyEquivalent(with: try keyEvent("\u{1B}")))

    #expect(keptAnswers.given == [ConflictResolution(choice: .keepBoth, appliesToAll: false)])
    #expect(cancelledAnswers.given == [nil])
}
