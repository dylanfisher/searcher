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

@MainActor @Test func rowsKeepAGapBetweenThemAndTheFirstKeepsATopInset() throws {
    let fixture = Fixture()
    let container = host(fixture, width: 400)

    fixture.controller.show([snapshot(1, .running), snapshot(2, .running)])
    container.layoutSubtreeIfNeeded()

    let first = try fixture.row(1)
    let second = try fixture.row(2)
    let (upper, lower) = first.frame.minY < second.frame.minY ? (first, second) : (second, first)
    #expect(lower.frame.minY - upper.frame.maxY == OperationsViewController.rowGap)
    let document = try #require(first.enclosingScrollView?.documentView)
    let topEdge = document.convert(first.frame, from: first.superview).minY
    #expect(topEdge == OperationsViewController.firstRowTopInset)
}

/// The rows' own 9 pt insets already part them, so the gap and the first row's extra room are
/// small: rows read apart, not loose (Dylan, 2026-10-26).
@MainActor @Test func theGapBetweenRowsAndAboveTheFirstIsSmall() {
    #expect(OperationsViewController.rowGap == 4)
    #expect(OperationsViewController.firstRowTopInset == 2)
}

/// Each row button fills a rounded shape under the mouse, a darker one while pressed, and none
/// while disabled, and its tracking area tells it when the mouse comes and goes.
/// A button hidden with an ancestor, or taken out of its window, gets no `mouseExited`, so it
/// drops the hover itself; shown again, it has no fill until the mouse comes back.
@MainActor @Test func aHoverButtonDropsItsHoverWhenHiddenOrMovedOutOfItsWindow() throws {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
        backing: .buffered, defer: true)
    let container = NSView()
    let button = HoverButton()
    container.addSubview(button)
    try #require(window.contentView).addSubview(container)
    let entered = try #require(
        NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))

    button.mouseEntered(with: entered)
    container.isHidden = true
    #expect(!button.isHovered)
    container.isHidden = false
    #expect(button.fill == nil)

    button.mouseEntered(with: entered)
    container.removeFromSuperview()
    #expect(!button.isHovered)
}

@MainActor @Test func theRowButtonsShowHoverPressedAndDisabledStates() throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running)])
    let row = try fixture.row(1)

    for button in [row.pauseButton, row.cancelButton] {
        #expect(
            button.trackingAreas.contains {
                $0.owner === button && $0.options.contains(.mouseEnteredAndExited)
            })
        #expect(button.fill == nil)
        let entered = try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        button.mouseEntered(with: entered)
        #expect(button.isHovered)
        #expect(button.fill == HoverButton.hoverFill)
        button.highlight(true)
        #expect(button.fill == HoverButton.pressedFill)
        button.highlight(false)
        button.isEnabled = false
        #expect(button.fill == nil)
        button.isEnabled = true
        let exited = try #require(
            NSEvent.enterExitEvent(
                with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        button.mouseExited(with: exited)
        #expect(!button.isHovered)
        #expect(button.fill == nil)
    }
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

/// An undo whose entry is dropped says so; one kept to try again once its drive is back doesn't.
@MainActor @Test func aDroppedUndoSaysSoInItsRow() throws {
    let fixture = Fixture()
    let record = OperationRecord(changes: [.moved(from: "/A/x", to: "/V/in/x")])
    let gone = FileOperationError(reason: .sourceGone, path: "/V", errno: ENOENT)

    fixture.controller.show([
        snapshot(
            1, .failed, operation: .undo(record, title: "Undo Move", isRetry: false), errors: [gone]
        ),
        snapshot(
            2, .failed, operation: .undo(record, title: "Undo Move", isRetry: true), errors: [gone]),
    ])

    #expect(try fixture.row(1).detailLabel.stringValue == "“/V” is gone.")
    #expect(
        try fixture.row(2).detailLabel.stringValue == "“/V” is gone. This undo is dropped.")
}

/// Puts the panel at the bottom of a view `width` wide, with nothing setting its height, as the
/// window does.
@MainActor
private func host(_ fixture: Fixture, width: CGFloat) -> NSView {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
    let panel = fixture.controller.view
    panel.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(panel)
    NSLayoutConstraint.activate([
        panel.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        panel.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        panel.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    container.layoutSubtreeIfNeeded()
    return container
}

@MainActor @Test func thePanelIsAsTallAsItsRowsUpToTheCapThenScrolls() throws {
    let fixture = Fixture()
    let container = host(fixture, width: 600)
    let panel = fixture.controller.view

    fixture.controller.show([snapshot(1, .running)])
    container.layoutSubtreeIfNeeded()
    let rowHeight = try fixture.row(1).frame.height
    let oneRow = panel.frame.height
    #expect(rowHeight > 0)
    // The separator and the first row's top inset over the rows, and nothing under the last row.
    let above = OperationsViewController.firstRowTopInset
    #expect(oneRow > rowHeight + above && oneRow <= rowHeight + above + 2)

    fixture.controller.show([snapshot(1, .running), snapshot(2, .running)])
    container.layoutSubtreeIfNeeded()
    #expect(panel.frame.height == oneRow + rowHeight + OperationsViewController.rowGap)

    fixture.controller.show((1...20).map { snapshot($0, .running) })
    container.layoutSubtreeIfNeeded()
    #expect(panel.frame.height == OperationsViewController.maxHeight)
    let scroll = try #require(try fixture.row(1).enclosingScrollView)
    let document = try #require(scroll.documentView)
    #expect(document.frame.height > scroll.contentView.bounds.height)

    fixture.controller.show([snapshot(1, .running)])
    container.layoutSubtreeIfNeeded()
    #expect(panel.frame.height == oneRow)
}

@MainActor @Test func theEmptyPanelIsOneLineSayingSo() throws {
    let fixture = Fixture()
    let container = host(fixture, width: 600)
    let panel = fixture.controller.view

    #expect(!fixture.controller.emptyLabel.isHiddenOrHasHiddenAncestor)
    #expect(panel.frame.height > 0 && panel.frame.height < OperationsViewController.maxHeight)

    fixture.controller.show([snapshot(1, .running)])
    container.layoutSubtreeIfNeeded()
    #expect(fixture.controller.emptyLabel.isHiddenOrHasHiddenAncestor)
}

@MainActor @Test func aRowsBarFillsTheWidthBesideItsButtonsAndTracksResizes() throws {
    let fixture = Fixture()
    let container = host(fixture, width: 600)
    fixture.controller.show([snapshot(1, .running)])
    container.layoutSubtreeIfNeeded()
    let row = try fixture.row(1)

    func gap() -> CGFloat {
        let bar = row.convert(row.bar.bounds, from: row.bar)
        let pause = row.convert(row.pauseButton.bounds, from: row.pauseButton)
        return pause.minX - bar.maxX
    }
    let wide = row.bar.frame.width
    #expect(gap() <= 8)

    container.setFrameSize(NSSize(width: 400, height: 600))
    container.layoutSubtreeIfNeeded()
    #expect(row.bar.frame.width == wide - 200)
    #expect(gap() <= 8)
}

@MainActor @Test func aProgressTickLaysOutNothingAboveTheRow() throws {
    let fixture = Fixture()
    let container = host(fixture, width: 600)
    let total = TreeSizeWalker.Total(bytes: 2_000_000, files: 4, isPartial: false)
    fixture.controller.show([snapshot(1, .running, total: total)])
    container.layoutSubtreeIfNeeded()
    let panel = fixture.controller.view
    let height = panel.frame.height

    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 1_000_000, files: 2), total: total)
    ])

    #expect(!panel.needsLayout)
    #expect(!container.needsLayout)
    container.layoutSubtreeIfNeeded()
    #expect(panel.frame.height == height)
}

@MainActor @Test func thePanelSaysWhenItsLastRowLeavesAndNotBefore() throws {
    let fixture = Fixture()
    var emptied = 0
    fixture.controller.onEmptied = { emptied += 1 }
    fixture.controller.show([])
    #expect(emptied == 0)

    fixture.controller.show([snapshot(1, .running), snapshot(2, .running)])
    fixture.controller.show([snapshot(1, .done), snapshot(2, .running)])
    #expect(emptied == 0)
    fixture.controller.show([snapshot(2, .done)])
    #expect(emptied == 1)

    let denied = FileOperationError(reason: .permissionDenied, path: "/dst/b.mov", errno: 13)
    fixture.controller.show([snapshot(3, .failed, errors: [denied])])
    #expect(emptied == 1)
    fixture.controller.clear(FileOperationQueue.ID(3))
    #expect(emptied == 2)
}

@MainActor @Test func aRowsContentSitsAtTheSharedBarInset() throws {
    let fixture = Fixture()
    let container = host(fixture, width: 600)
    fixture.controller.show([snapshot(1, .running)])
    container.layoutSubtreeIfNeeded()
    let row = try fixture.row(1)

    let bar = row.convert(row.bar.bounds, from: row.bar)
    let cancel = row.convert(row.cancelButton.bounds, from: row.cancelButton)
    #expect(bar.minX == BarInset.horizontal)
    #expect(row.bounds.maxX - cancel.maxX == BarInset.horizontal)
}

private let bigTotal = TreeSizeWalker.Total(bytes: 6_000_000_000, files: 700, isPartial: false)

@MainActor @Test func aCopyEstimatedToRunLongShowsThePanelBeforeTheDelay() throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running, total: bigTotal)])
    #expect(fixture.log.attention == 0)

    // 100 MB a second leaves about a minute to go.
    fixture.clock.advance(by: .milliseconds(100))
    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 10_000_000, files: 1), total: bigTotal)
    ])
    #expect(fixture.log.attention == 1)

    // It asks once, not with every tick.
    fixture.clock.advance(by: .milliseconds(100))
    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 20_000_000, files: 2), total: bigTotal)
    ])
    #expect(fixture.log.attention == 1)
}

@MainActor @Test func aBigCopyThatGoesFastNeverShowsThePanel() async throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running, total: bigTotal)])
    await settle { fixture.clock.waitingSleeps == 1 }

    // A clone on one volume: nearly all of it in the first tick.
    fixture.clock.advance(by: .milliseconds(100))
    fixture.controller.show([
        snapshot(
            1, .running, copied: CopyProgress(bytes: 5_500_000_000, files: 600), total: bigTotal)
    ])
    fixture.controller.show([snapshot(1, .done)])
    fixture.controller.show([])
    fixture.clock.advance(by: .seconds(2))
    try? await Task.sleep(for: .milliseconds(20))

    #expect(fixture.log.attention == 0)
}

@MainActor @Test func anOperationAsksOnceSoAClosedPanelStaysClosed() async throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running)])
    await settle { fixture.clock.waitingSleeps == 1 }
    fixture.clock.advance(by: .seconds(1))
    await settle { fixture.log.attention == 1 }

    // The user closes the panel; the operation goes on ticking.
    fixture.controller.show([snapshot(1, .running)])
    fixture.clock.advance(by: .seconds(1))
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fixture.clock.waitingSleeps == 0)
    #expect(fixture.log.attention == 1)

    // Another operation still asks.
    fixture.controller.show([snapshot(1, .running), snapshot(2, .running)])
    await settle { fixture.clock.waitingSleeps == 1 }
    fixture.clock.advance(by: .seconds(1))
    await settle { fixture.log.attention == 2 }
}

@MainActor @Test func anEarlyAskReplacesTheOneSecondWait() async throws {
    let fixture = Fixture()
    fixture.controller.show([snapshot(1, .running, total: bigTotal)])
    await settle { fixture.clock.waitingSleeps == 1 }
    fixture.clock.advance(by: .milliseconds(100))
    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 10_000_000, files: 1), total: bigTotal)
    ])
    #expect(fixture.log.attention == 1)

    fixture.clock.advance(by: .seconds(1))
    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 20_000_000, files: 2), total: bigTotal)
    ])
    try? await Task.sleep(for: .milliseconds(20))
    #expect(fixture.log.attention == 1)
}

/// Shows a running copy of `total` bytes at the clock's time zero and then, 100 ms later, with
/// `copied` of them done.
@MainActor private func showTick(
    _ fixture: Fixture, copied: Int64, of total: Int64, phase: OperationState.Phase = .running
) {
    let total = TreeSizeWalker.Total(bytes: total, files: 1, isPartial: false)
    fixture.controller.show([snapshot(1, .running, total: total)])
    fixture.clock.advance(by: .milliseconds(100))
    fixture.controller.show([
        snapshot(1, phase, copied: CopyProgress(bytes: copied, files: 0), total: total)
    ])
}

@MainActor @Test func aCopyEstimatedJustUnderTwoSecondsWaits() {
    let fixture = Fixture()
    // 1 GB a second, 1.9 s to go.
    showTick(fixture, copied: 100_000_000, of: 2_000_000_000)

    #expect(fixture.log.attention == 0)
}

@MainActor @Test func aCopyEstimatedJustOverTwoSecondsAsks() {
    let fixture = Fixture()
    // 1 GB a second, 2.1 s to go.
    showTick(fixture, copied: 100_000_000, of: 2_200_000_000)

    #expect(fixture.log.attention == 1)
}

@MainActor @Test func aTickWithNoBytesMovedAsksNothing() {
    let fixture = Fixture()
    showTick(fixture, copied: 0, of: 6_000_000_000)
    fixture.clock.advance(by: .milliseconds(100))
    fixture.controller.show([snapshot(1, .running, total: bigTotal)])

    #expect(fixture.log.attention == 0)
}

@MainActor @Test func aPauseStartsTheSamplingOver() {
    let fixture = Fixture()
    // Paused 100 ms in with 10 MB done: no rate is read across the pause.
    showTick(fixture, copied: 10_000_000, of: 6_000_000_000, phase: .paused)
    #expect(fixture.log.attention == 0)

    // Resumed, it copies the rest at once.
    fixture.clock.advance(by: .milliseconds(500))
    fixture.controller.show([
        snapshot(1, .running, copied: CopyProgress(bytes: 10_000_000, files: 0), total: bigTotal)
    ])
    fixture.clock.advance(by: .milliseconds(100))
    fixture.controller.show([
        snapshot(
            1, .running, copied: CopyProgress(bytes: 5_900_000_000, files: 0), total: bigTotal)
    ])
    #expect(fixture.log.attention == 0)
}
