import AppKit
import Base
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// An operations panel that is never shown, on a clock the test moves, logging the calls its
/// buttons send and each time it asks to be shown.
@MainActor
private struct Fixture {
    enum Call: Equatable {
        case pause(FileOperationQueue.ID)
        case resume(FileOperationQueue.ID)
        case cancel(FileOperationQueue.ID)
    }

    @MainActor final class Log {
        var calls: [Call] = []
        var attention = 0
    }

    let controller: OperationsViewController
    let clock = ManualClock()
    let log = Log()

    init() {
        let log = log
        let clock = clock
        controller = OperationsViewController(
            control: OperationsViewController.Control(
                pause: { log.calls.append(.pause($0)) },
                resume: { log.calls.append(.resume($0)) },
                cancel: { log.calls.append(.cancel($0)) }),
            clock: clock)
        controller.onNeedsAttention = { log.attention += 1 }
        controller.view.layoutSubtreeIfNeeded()
    }

    func row(_ id: Int) throws -> OperationRowView {
        try #require(controller.row(for: FileOperationQueue.ID(id)))
    }
}

private let copy = FileOperation.copy(["/src/a.mov", "/src/b.mov"], into: "/dst")

private func snapshot(
    _ id: Int, _ phase: OperationState.Phase, operation: FileOperation = copy,
    copied: CopyProgress = CopyProgress(bytes: 0, files: 0),
    total: TreeSizeWalker.Total? = nil, errors: [FileOperationError] = []
) -> FileOperationQueue.Snapshot {
    FileOperationQueue.Snapshot(
        id: FileOperationQueue.ID(id), operation: operation,
        state: OperationState(
            phase: phase,
            progress: OperationState.Progress(
                itemsDone: 0, itemCount: 2, copied: copied, total: total),
            errors: errors, record: OperationRecord()))
}

@MainActor @Test func stubSnapshotsUpdateARowsProgressTextAndBar() throws {
    let fixture = Fixture()
    let total = TreeSizeWalker.Total(bytes: 2_000_000, files: 4, isPartial: false)
    let sizes = EntryCellFormatter()

    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 500_000, files: 1), total: total)
    ])
    let row = try fixture.row(1)
    #expect(row.titleLabel.stringValue == "Copying 2 items to “dst”")
    #expect(
        row.detailLabel.stringValue
            == "\(sizes.bytes(500_000)) of \(sizes.bytes(2_000_000)), 1 of 4 files")
    #expect(!row.bar.isIndeterminate)
    #expect(row.bar.doubleValue == 0.25)

    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 1_500_000, files: 3), total: total)
    ])
    #expect(try fixture.row(1) === row)
    #expect(
        row.detailLabel.stringValue
            == "\(sizes.bytes(1_500_000)) of \(sizes.bytes(2_000_000)), 3 of 4 files")
    #expect(row.bar.doubleValue == 0.75)
}

@MainActor @Test func aRowWithoutATotalShowsAMovingBar() throws {
    let fixture = Fixture()

    fixture.controller.show([snapshot(1, .preparing)])

    let row = try fixture.row(1)
    #expect(row.bar.isIndeterminate)
    #expect(row.detailLabel.stringValue == "Preparing…")
}

@MainActor @Test func pauseAndCancelSendThoseCallsForThatOperationID() throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running), snapshot(2, .running)])

    try fixture.row(2).pauseButton.performClick(nil)
    fixture.controller.show([snapshot(1, .running), snapshot(2, .paused)])
    try fixture.row(2).pauseButton.performClick(nil)
    try fixture.row(1).cancelButton.performClick(nil)

    let first = FileOperationQueue.ID(1)
    let second = FileOperationQueue.ID(2)
    #expect(fixture.log.calls == [.pause(second), .resume(second), .cancel(first)])
    #expect(try fixture.row(2).detailLabel.stringValue.hasPrefix("Paused"))
}

@MainActor @Test func aRowSetsItsButtonImagesOnlyWhenThePhaseChanges() throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running)])
    let row = try fixture.row(1)
    let pause = try #require(row.pauseButton.image)
    let cancel = try #require(row.cancelButton.image)

    fixture.controller.show([snapshot(1, .running, copied: CopyProgress(bytes: 10, files: 1))])
    #expect(row.pauseButton.image === pause)
    #expect(row.cancelButton.image === cancel)

    fixture.controller.show([snapshot(1, .paused)])
    #expect(row.pauseButton.image !== pause)
    #expect(row.cancelButton.image === cancel)
}

@MainActor @Test func aFinishedOperationLeavesThePanelAndAFailedOneShowsItsErrorWithThePath()
    throws
{
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running), snapshot(2, .running)])

    let denied = FileOperationError(reason: .permissionDenied, path: "/dst/b.mov", errno: 13)
    fixture.controller.show([snapshot(1, .done), snapshot(2, .failed, errors: [denied])])
    // A finished operation is in one snapshot, then leaves the list.
    fixture.controller.show([])

    #expect(fixture.controller.row(for: FileOperationQueue.ID(1)) == nil)
    let failed = try fixture.row(2)
    #expect(failed.detailLabel.stringValue.contains("/dst/b.mov"))
    #expect(failed.pauseButton.isHidden)
    #expect(fixture.log.attention == 1)

    failed.cancelButton.performClick(nil)

    #expect(fixture.controller.row(for: FileOperationQueue.ID(2)) == nil)
    #expect(fixture.log.calls.isEmpty)
}

@MainActor @Test func aRefusedOperationSaysWhichPathIsInUse() throws {
    let fixture = Fixture()

    fixture.controller.show([
        snapshot(1, .refused(.inUse(path: "/src/a.mov")), operation: .trash(["/src/a.mov"]))
    ])

    #expect(try fixture.row(1).detailLabel.stringValue.contains("/src/a.mov"))
    #expect(fixture.log.attention == 1)
}

@MainActor @Test func aShortOperationNeverShowsThePanel() async throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running)])
    await settle { fixture.clock.waitingSleeps == 1 }

    fixture.controller.show([snapshot(1, .done)])
    fixture.controller.show([])
    fixture.clock.advance(by: .seconds(2))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(fixture.log.attention == 0)
}

@MainActor @Test func anOperationRunningPastOneSecondShowsThePanel() async throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running)])
    await settle { fixture.clock.waitingSleeps == 1 }

    fixture.clock.advance(by: .milliseconds(999))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fixture.log.attention == 0)
    fixture.clock.advance(by: .milliseconds(1))

    await settle { fixture.log.attention == 1 }
}
