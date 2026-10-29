import AppKit
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A document view that logs the drag calls it gets.
@MainActor
private final class DragLog: NSView {
    var calls: [String] = []

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        calls.append("entered")
        return .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        calls.append("updated")
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        calls.append("exited")
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        calls.append("prepare")
        return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        calls.append("perform")
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        calls.append("conclude")
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        calls.append("ended")
    }
}

/// A list of two rows in a view standing in for the pane: its scroll view, and a point in each
/// margin, in the pane's coordinates.
@MainActor
private func shortList() async throws -> (
    list: ListingViewController, pane: NSView, top: NSPoint, bottom: NSPoint
) {
    let list = await controller(showing: [file("a"), file("b")])
    let pane = NSView(frame: list.view.frame)
    pane.addSubview(list.view)
    pane.layoutSubtreeIfNeeded()
    let scrollView = try #require(list.view as? NSScrollView)
    let header = try #require(list.tableView.headerView)
    let headerBottom = scrollView.convert(header.bounds, from: header).maxY
    let clipBottom = scrollView.contentView.frame.maxY
    func inPane(_ y: CGFloat) -> NSPoint {
        pane.convert(NSPoint(x: 20, y: y), from: scrollView)
    }
    return (list, pane, inPane(headerBottom + 2), inPane(clipBottom - 2))
}

/// A press in the margin above the first row or below the last lands on the table, which takes
/// it as a press below the rows, as Finder does.
@MainActor @Test func aPressInAListsMarginsHitsItsTable() async throws {
    let (list, pane, top, bottom) = try await shortList()

    #expect(list.tableView.row(at: list.tableView.convert(top, from: pane)) == -1)
    #expect(pane.hitTest(top) === list.tableView)
    #expect(list.tableView.row(at: list.tableView.convert(bottom, from: pane)) == -1)
    #expect(pane.hitTest(bottom) === list.tableView)
}

/// The margins take what the table takes, and pass each drag call on to it.
@MainActor @Test func aDragOverAMarginGoesOnToTheTable() async throws {
    let (list, _, _, _) = try await shortList()
    let clip = try #require((list.view as? NSScrollView)?.contentView as? ListingClipView)
    #expect(
        Set(clip.registeredDraggedTypes) == Set(list.tableView.registeredDraggedTypes))
    #expect(!clip.registeredDraggedTypes.isEmpty)

    let log = DragLog(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let spare = ListingClipView()
    spare.documentView = log
    let pasteboard = testPasteboard()
    defer { pasteboard.releaseGlobally() }
    let info = StubDraggingInfo(pasteboard: pasteboard)

    #expect(spare.draggingEntered(info) == .copy)
    #expect(spare.draggingUpdated(info) == .move)
    spare.draggingExited(info)
    #expect(spare.prepareForDragOperation(info))
    #expect(spare.performDragOperation(info))
    spare.concludeDragOperation(info)
    spare.draggingEnded(info)
    #expect(
        log.calls == ["entered", "updated", "exited", "prepare", "perform", "conclude", "ended"])
}

/// The path bar's glass hands a drag to the clip under it once: entering the glass again while
/// the clip still holds the drag updates it rather than entering it twice, and a drop and the
/// drag's end reach it (docs/decisions/0132-glass-path-bar.md).
@MainActor @Test func theGlassEntersAClipOnceAndPassesTheDropOn() {
    let log = DragLog(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    let clip = ListingClipView()
    clip.documentView = log
    let glass = PathBarGlassContent()
    glass.listClip = { _ in clip }
    let pasteboard = testPasteboard()
    defer { pasteboard.releaseGlobally() }
    let info = StubDraggingInfo(pasteboard: pasteboard)

    #expect(glass.draggingEntered(info) == .copy)
    #expect(glass.draggingEntered(info) == .move)
    #expect(glass.prepareForDragOperation(info))
    #expect(glass.performDragOperation(info))
    glass.concludeDragOperation(info)
    glass.draggingEnded(info)

    #expect(log.calls == ["entered", "updated", "prepare", "perform", "conclude", "ended"])
}
