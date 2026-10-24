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

@MainActor @Test func stopAnswersNothing() {
    let (sheet, answers) = sheet()

    sheet.stopButton.performClick(nil)

    #expect(answers.given == [nil])
}

/// Finder's question, with both items' size and date under it.
@MainActor @Test func theSheetAsksAsFinderDoesAndShowsBothItems() {
    let (sheet, _) = sheet()
    let formatter = EntryCellFormatter()
    let lines = sheet.dialog.informationLabel.stringValue.split(separator: "\n").map(String.init)

    #expect(
        sheet.dialog.messageLabel.stringValue
            == "An item named “report.pdf” already exists in this location.")
    #expect(lines.count == 3)
    #expect(lines[0] == "Do you want to replace it with the one you’re adding?")
    #expect(lines[1].contains(formatter.bytes(1_000)))
    #expect(lines[1].contains(formatter.date(modified.addingTimeInterval(-86_400))))
    #expect(lines[2].contains(formatter.bytes(2_000_000)))
    #expect(lines[2].contains(formatter.date(modified)))
}

@MainActor @Test func applyToAllShowsOnlyWhenMoreConflictsFollow() {
    let (last, _) = sheet(remaining: 0)
    let (more, _) = sheet(remaining: 3)

    #expect(last.applyToAllBox.isHidden)
    #expect(!more.applyToAllBox.isHidden)
    #expect(more.applyToAllBox.title == "Apply to All")
}

/// Finder's row, left to right: Keep Both, Stop, Skip, Replace. Replace is the default and
/// takes Return; Stop takes Esc.
@MainActor @Test func theButtonsAreFindersRowWithReplaceAsTheDefault() {
    let (sheet, _) = sheet()
    let row = sheet.dialog.buttons.sorted { $0.frame.minX < $1.frame.minX }

    #expect(row.map(\.title) == ["Keep Both", "Stop", "Skip", "Replace"])
    #expect(row == [sheet.keepBothButton, sheet.stopButton, sheet.skipButton, sheet.replaceButton])
    #expect(Set(row.map(\.frame.minY)).count == 1)
    #expect(row.map(\.keyEquivalent) == ["", "\u{1B}", "", "\r"])
    #expect(row.allSatisfy { $0.window === sheet.panel })
}

@MainActor @Test func returnReplacesAndEscStops() throws {
    let (replaced, replacedAnswers) = sheet()
    let (stopped, stoppedAnswers) = sheet()

    #expect(replaced.panel.performKeyEquivalent(with: try keyEvent("\r")))
    #expect(stopped.panel.performKeyEquivalent(with: try keyEvent("\u{1B}")))

    #expect(replacedAnswers.given == [ConflictResolution(choice: .replace, appliesToAll: false)])
    #expect(stoppedAnswers.given == [nil])
}
