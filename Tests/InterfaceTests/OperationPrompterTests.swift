import AppKit
import Base
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// A prompter over a window that is never shown, whose sheets are recorded instead of shown.
@MainActor
private final class Fixture {
    let prompter: OperationPrompter
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: true)
    var hasWindow = true
    var presented: [NSWindow] = []
    var dismissed: [NSWindow] = []

    init() {
        prompter = OperationPrompter()
        prompter.window = { [unowned self] in hasWindow ? window : nil }
        prompter.present = { [unowned self] sheet, _ in presented.append(sheet) }
        prompter.dismiss = { [unowned self] sheet in dismissed.append(sheet) }
    }

    var confirmSheet: ConfirmSheetController? {
        if case .confirm(let sheet) = prompter.shown { sheet } else { nil }
    }

    var conflictSheet: ConflictSheetController? {
        if case .conflict(let sheet) = prompter.shown { sheet } else { nil }
    }
}

/// Answers handed back by the prompter's calls, in the order they returned.
@MainActor
private final class Returned {
    var confirms: [Bool] = []
    var resolutions: [ConflictResolution] = []
}

private func otherPane(_ name: String) -> ConfirmRequest {
    .otherPane(.copy(["/a/\(name)"], into: "/b"))
}

private func conflict(_ operation: Int) -> ConflictRequest {
    let item = ConflictRequest.Item(
        path: "/b/x.txt", isFolder: false, bytes: 1, modified: Date(timeIntervalSince1970: 0))
    return ConflictRequest(
        operation: FileOperationQueue.ID(operation), source: item, existing: item, remaining: 0)
}

@MainActor
private func ask(_ request: ConfirmRequest, of fixture: Fixture, into returned: Returned) {
    let prompts = fixture.prompter.prompts
    Task { @MainActor in returned.confirms.append(await prompts.confirm(request)) }
}

@MainActor @Test func twoQuestionsAskedBeforeAnAnswerShowOneAtATime() async throws {
    let fixture = Fixture()
    let returned = Returned()

    ask(otherPane("one"), of: fixture, into: returned)
    ask(otherPane("two"), of: fixture, into: returned)
    await settle { fixture.prompter.waitingCount == 1 }

    #expect(fixture.presented.count == 1)
    let first = try #require(fixture.confirmSheet)
    #expect(first.messageLabel.stringValue.contains("one"))

    first.confirmButton.performClick(nil)
    await settle { returned.confirms == [true] && fixture.presented.count == 2 }

    #expect(fixture.dismissed.count == 1)
    let second = try #require(fixture.confirmSheet)
    #expect(second.messageLabel.stringValue.contains("two"))
    second.cancelButton.performClick(nil)
    await settle { returned.confirms == [true, false] }
    #expect(fixture.prompter.shown == nil)
}

@MainActor @Test func aQuestionWaitsForAWindow() async throws {
    let fixture = Fixture()
    fixture.hasWindow = false
    let returned = Returned()

    ask(otherPane("one"), of: fixture, into: returned)
    await settle { fixture.prompter.waitingCount == 1 }
    #expect(fixture.presented.isEmpty)

    fixture.hasWindow = true
    fixture.prompter.showNext()

    #expect(fixture.presented.count == 1)
    #expect(fixture.confirmSheet != nil)
}

@MainActor @Test func aQuestionOnAWindowThatClosesShowsOnTheNextWindow() async throws {
    let fixture = Fixture()
    let returned = Returned()
    ask(otherPane("one"), of: fixture, into: returned)
    await settle { fixture.confirmSheet != nil }
    let closed = fixture.window
    let next = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled],
        backing: .buffered, defer: true)
    var shownOn: [NSWindow] = []
    fixture.prompter.window = { next }
    fixture.prompter.present = { _, window in shownOn.append(window) }

    fixture.prompter.windowClosed(closed)

    #expect(shownOn == [next])
    #expect(fixture.dismissed.count == 1)
    let sheet = try #require(fixture.confirmSheet)
    sheet.confirmButton.performClick(nil)
    await settle { returned.confirms == [true] }
}

@MainActor @Test func aQuestionClosesWhenASnapshotShowsItsOperationFinished() async throws {
    let fixture = Fixture()
    let returned = Returned()
    let prompts = fixture.prompter.prompts
    Task { @MainActor in returned.resolutions.append(await prompts.resolve(conflict(7))) }
    ask(otherPane("next"), of: fixture, into: returned)
    await settle { fixture.conflictSheet != nil && fixture.prompter.waitingCount == 1 }

    fixture.prompter.operationsChanged([
        FileOperationQueue.Snapshot(
            id: FileOperationQueue.ID(7), operation: .copy(["/a/x.txt"], into: "/b"),
            state: OperationState(
                phase: .cancelled(leftBehind: nil),
                progress: OperationState.Progress(
                    itemsDone: 0, itemCount: 1, copied: CopyProgress(bytes: 0, files: 0),
                    total: nil),
                errors: [], record: OperationRecord()))
    ])

    await settle { returned.resolutions.count == 1 }
    #expect(fixture.dismissed.count == 1)
    #expect(fixture.confirmSheet != nil)

    // A question for an operation already seen finished is never shown.
    Task { @MainActor in returned.resolutions.append(await prompts.resolve(conflict(7))) }
    await settle { returned.resolutions.count == 2 }
    #expect(fixture.presented.count == 2)
}

@MainActor @Test func cancelOnAConflictSheetCancelsItsOperation() async throws {
    let folder = try TemporaryFolder("ConflictCancel")
    let source = folder.url.appending(path: "src")
    let destination = folder.url.appending(path: "dst")
    for url in [source, destination] {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        try Data("text".utf8).write(to: url.appending(path: "a.txt"))
    }
    let fixture = Fixture()
    let queue = FileOperationQueue(prompts: fixture.prompter.prompts) { _ in }
    fixture.prompter.queue = queue
    var finished: OperationState?
    let operation = FileOperation.copy(
        [source.appending(path: "a.txt").path], into: destination.path)
    Task { @MainActor in finished = await queue.perform(operation) }
    await settle { fixture.conflictSheet != nil }

    try #require(fixture.conflictSheet).cancelButton.performClick(nil)
    await settle { finished != nil }

    #expect(finished?.phase == .cancelled(leftBehind: nil))
    #expect(finished?.record.changes == [])
    #expect(fixture.prompter.shown == nil)
}
