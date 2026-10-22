import AppKit
import Browser
import Foundation
import Testing

@testable import Interface

private let size = NSSize(width: 800, height: 500)

/// Two panes side by side, or stacked for `.vertical`, in a window that is never shown, so mouse
/// events have window coordinates to convert from.
@MainActor
private struct TwoPanes {
    let view: PaneLayoutView
    let window: NSWindow

    init(
        _ axis: Axis = .horizontal,
        makeView: @MainActor (Layout, [PaneID: NSView]) -> PaneLayoutView = PaneLayoutView.init
    ) throws {
        var layout = Layout()
        try splitPane(&layout, axis, in: Rect(CGRect(origin: .zero, size: size)))
        view = makeView(layout, paneViews(for: layout))
        view.frame = NSRect(origin: .zero, size: size)
        window = NSWindow(
            contentRect: view.frame, styleMask: [.titled, .resizable], backing: .buffered,
            defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = view
    }

    var bounds: Rect { Rect(view.bounds) }

    var divider: Layout.Divider {
        get throws { try #require(view.layout.dividers(in: bounds).first) }
    }
}

/// Splits the focused pane and returns the new one, failing the test if the split is refused.
@discardableResult
private func splitPane(_ layout: inout Layout, _ axis: Axis, in rect: Rect) throws -> PaneID {
    let new = layout.split(axis, in: rect)
    return try #require(new)
}

@MainActor
private func paneViews(for layout: Layout) -> [PaneID: NSView] {
    Dictionary(uniqueKeysWithValues: layout.panes.map { ($0, NSView()) })
}

/// The ratio of the root split.
private func rootRatio(_ layout: Layout) throws -> Double {
    guard case .split(_, let ratio, _, _) = layout.root else {
        Issue.record("the layout has no split")
        return .nan
    }
    return ratio
}

private func isClose(_ a: Double, _ b: Double) -> Bool {
    abs(a - b) < 1e-9
}

private func value(of element: NSAccessibilityElement) throws -> Double {
    try #require(element.accessibilityValue() as? NSNumber).doubleValue
}

@MainActor
private func expectPaneFramesMatchModel(_ view: PaneLayoutView) {
    let frames = view.layout.frames(in: Rect(view.bounds))
    #expect(view.subviews.count == frames.count)
    for (pane, frame) in frames {
        #expect(view.paneView(for: pane).frame == CGRect(frame), "\(pane)")
    }
}

/// Sends a press at `from`, one drag to `to` and a release there, all in the view's coordinates.
@MainActor
private func drag(_ view: PaneLayoutView, from: NSPoint, to: NSPoint) throws {
    let window = try #require(view.window)
    func event(_ type: NSEvent.EventType, _ point: NSPoint) throws -> NSEvent {
        try #require(
            NSEvent.mouseEvent(
                with: type, location: view.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1))
    }
    #expect(view.hitTest(view.convert(from, to: view.superview)) === view)
    view.mouseDown(with: try event(.leftMouseDown, from))
    view.mouseDragged(with: try event(.leftMouseDragged, to))
    view.mouseUp(with: try event(.leftMouseUp, to))
}

@MainActor
private func splitter(of view: PaneLayoutView) throws -> NSAccessibilityElement {
    let splitters = (view.accessibilityChildren() ?? [])
        .compactMap { $0 as? NSAccessibilityElement }
        .filter { $0.accessibilityRole() == .splitter }
    try #require(splitters.count == 1)
    return splitters[0]
}

@MainActor @Test func paneFramesFollowLayoutBeforeAndAfterResize() throws {
    let fixture = try TwoPanes()
    expectPaneFramesMatchModel(fixture.view)

    fixture.view.setFrameSize(NSSize(width: 1100, height: 640))
    expectPaneFramesMatchModel(fixture.view)

    fixture.view.setFrameSize(NSSize(width: 500, height: 300))
    expectPaneFramesMatchModel(fixture.view)
}

@MainActor @Test func dividerDragSetsRatioAndStopsAtMinimumSize() throws {
    let fixture = try TwoPanes()
    let divider = try fixture.divider
    // Grab beside the 1 pt divider, inside the wider drag area, so the offset is kept.
    let grab = NSPoint(x: divider.rect.maxX + 2, y: 250)

    try drag(fixture.view, from: grab, to: NSPoint(x: grab.x - 100, y: 260))
    let expected = divider.ratio(at: divider.rect.minX - 100)
    #expect(isClose(try rootRatio(fixture.view.layout), expected))
    expectPaneFramesMatchModel(fixture.view)

    let moved = try fixture.divider
    try drag(fixture.view, from: NSPoint(x: moved.rect.minX, y: 250), to: NSPoint(x: 5, y: 250))
    let left = try #require(
        fixture.view.layout.frames(in: fixture.bounds)[fixture.view.layout.panes[0]])
    #expect(isClose(left.width, Layout.minimumPaneSize))
    expectPaneFramesMatchModel(fixture.view)
}

@MainActor @Test(arguments: [Axis.horizontal, .vertical])
func dividerHasResizeCursorRect(axis: Axis) throws {
    let fixture = try TwoPanes(axis, makeView: CursorRecordingLayoutView.init)
    let view = try #require(fixture.view as? CursorRecordingLayoutView)
    let divider = try fixture.divider

    view.resetCursorRects()

    try #require(view.cursorRects.count == 1)
    let (rect, cursor) = view.cursorRects[0]
    #expect(rect.contains(CGRect(divider.rect)))
    #expect(cursor == (axis == .horizontal ? NSCursor.resizeLeftRight : .resizeUpDown))
}

@MainActor @Test(arguments: [Axis.horizontal, .vertical])
func dividerIsAnAccessibleSplitterWhoseValueFollowsTheRatio(axis: Axis) throws {
    let fixture = try TwoPanes(axis)
    let element = try splitter(of: fixture.view)

    // The splitter's orientation is the divider line's, across the split's axis.
    #expect(element.accessibilityOrientation() == (axis == .horizontal ? .vertical : .horizontal))
    #expect(element.accessibilityFrameInParentSpace().contains(CGRect(try fixture.divider.rect)))
    #expect(isClose(try value(of: element), 0.5))

    let divider = try fixture.divider
    let grab = NSPoint(x: divider.rect.minX, y: divider.rect.minY)
    let target =
        axis == .horizontal
        ? NSPoint(x: grab.x + 60, y: grab.y) : NSPoint(x: grab.x, y: grab.y + 60)
    try drag(fixture.view, from: grab, to: target)
    let dragged = try rootRatio(fixture.view.layout)
    #expect(dragged > 0.5)
    #expect(try splitter(of: fixture.view) === element)
    #expect(isClose(try value(of: element), dragged))

    #expect(element.accessibilityPerformDecrement())
    let decremented = try rootRatio(fixture.view.layout)
    #expect(decremented < dragged)
    #expect(isClose(try value(of: element), decremented))

    #expect(element.accessibilityPerformIncrement())
    #expect(isClose(try rootRatio(fixture.view.layout), dragged))

    element.setAccessibilityValue(NSNumber(value: 0.4))
    #expect(isClose(try rootRatio(fixture.view.layout), 0.4))
    #expect(isClose(try value(of: element), 0.4))
}

@MainActor @Test func ninePanesApplyAndReportTheTime() throws {
    let bounds = Rect(x: 0, y: 0, width: 1800, height: 1200)
    var layout = Layout()
    var columns = [layout.focused]
    for _ in 0..<2 { columns.append(try splitPane(&layout, .horizontal, in: bounds)) }
    for column in columns {
        layout.focus(column)
        for _ in 0..<2 { try splitPane(&layout, .vertical, in: bounds) }
    }
    layout.equalize(in: bounds)
    try #require(layout.panes.count == 9)

    let view = PaneLayoutView(layout: layout, paneViews: paneViews(for: layout))
    let sizes = [NSSize(width: 1800, height: 1200), NSSize(width: 1700, height: 1100)]
    var times: [Duration] = []
    let clock = ContinuousClock()
    for run in 0..<200 {
        let size = sizes[run % 2]
        times.append(clock.measure { view.setFrameSize(size) })
    }
    expectPaneFramesMatchModel(view)
    let median = times.sorted()[times.count / 2]
    let milliseconds = median.formatted(
        .units(allowed: [.milliseconds], fractionalPart: .show(length: 3)))
    print("PaneLayoutView applies 9 panes in \(milliseconds) (median of \(times.count) resizes)")
}

/// Shows the two-pane fixture for checking the divider cursor and VoiceOver by hand. Skipped unless
/// `SEARCHER_LAYOUT_FIXTURE` is set; it returns when the window is closed.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCHER_LAYOUT_FIXTURE"] != nil))
func twoPaneFixtureForManualCheck() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()

    var layout = Layout()
    let bounds = Rect(CGRect(origin: .zero, size: size))
    try splitPane(&layout, .horizontal, in: bounds)
    let labels = ["Left pane", "Right pane"].map(NSTextField.init(labelWithString:))
    let view = PaneLayoutView(
        layout: layout,
        paneViews: Dictionary(uniqueKeysWithValues: zip(layout.panes, labels)))

    // Secondary display when there is one, and never activated, so it doesn't take focus.
    let screen = try #require(NSScreen.screens.dropFirst().first ?? NSScreen.screens.first)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false,
        screen: screen)
    window.title = "Two-pane layout fixture"
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.setFrameOrigin(
        NSPoint(
            x: screen.visibleFrame.midX - size.width / 2,
            y: screen.visibleFrame.midY - size.height / 2))
    window.orderFrontRegardless()

    while window.isVisible {
        if let event = app.nextEvent(
            matching: .any, until: .distantFuture, inMode: .default, dequeue: true)
        {
            app.sendEvent(event)
        }
    }
}

/// Records the cursor rects the view adds, which AppKit gives no way to read back.
private final class CursorRecordingLayoutView: PaneLayoutView {
    var cursorRects: [(NSRect, NSCursor)] = []

    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        cursorRects.append((rect, cursor))
    }
}
