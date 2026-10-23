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

    #expect(sheet.messageLabel.stringValue.contains("“report.pdf”"))
    #expect(sheet.messageLabel.stringValue.contains("“dst”"))
    #expect(sheet.existingLabel.stringValue.contains(formatter.bytes(1_000)))
    #expect(
        sheet.existingLabel.stringValue.contains(
            formatter.date(modified.addingTimeInterval(-86_400))))
    #expect(sheet.sourceLabel.stringValue.contains(formatter.bytes(2_000_000)))
    #expect(sheet.sourceLabel.stringValue.contains(formatter.date(modified)))
}

@MainActor @Test func applyToAllShowsOnlyWhenMoreConflictsFollow() {
    let (last, _) = sheet(remaining: 0)
    let (more, _) = sheet(remaining: 3)

    #expect(last.applyToAllBox.isHidden)
    #expect(!more.applyToAllBox.isHidden)
    #expect(more.applyToAllBox.title.contains("3"))
}
