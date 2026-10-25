import AppKit
import Testing

@testable import Interface

/// A left-mouse event at `x` in the window's coordinates, as AppKit hands it to the grip.
@MainActor
func gripEvent(
    _ type: NSEvent.EventType, x: Double, option: Bool = false, clicks: Int = 1
) -> NSEvent {
    guard
        let event = NSEvent.mouseEvent(
            with: type, location: NSPoint(x: x, y: 4), modifierFlags: option ? .option : [],
            timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks,
            pressure: 1)
    else { preconditionFailure("AppKit made no \(type) event") }
    return event
}

/// Drags `grip` `offset` points to the right, Option held or not, as a press, one move and a
/// release.
@MainActor
func drag(_ grip: ColumnGripView, by offset: Double, option: Bool = false) {
    grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100, option: option))
    grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 100 + offset, option: option))
    grip.mouseUp(with: gripEvent(.leftMouseUp, x: 100 + offset, option: option))
}

/// Double-clicks `grip`, Option held or not, as AppKit sends it: a click, then a press with a
/// click count of two.
@MainActor
func doubleClick(_ grip: ColumnGripView, option: Bool = false) {
    grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100, option: option))
    grip.mouseUp(with: gripEvent(.leftMouseUp, x: 100, option: option))
    grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100, option: option, clicks: 2))
    grip.mouseUp(with: gripEvent(.leftMouseUp, x: 100, option: option, clicks: 2))
}

/// What a grip reported, in order.
@MainActor
private final class GripLog {
    var calls: [String] = []
    var width = 286.0

    func attach(to grip: ColumnGripView) {
        grip.beginResize = { [unowned self] all in calls.append("begin \(all)") }
        grip.resize = { [unowned self] offset in calls.append("resize \(offset)") }
        grip.endResize = { [unowned self] in calls.append("end") }
        grip.fit = { [unowned self] all in calls.append("fit \(all)") }
        grip.width = { [unowned self] in width }
        grip.setWidth = { [unowned self] width in self.width = width }
    }
}

@MainActor @Test func aDragReportsItsOffsetFromWhereItStarted() {
    let grip = ColumnGripView(
        frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 400))
    let log = GripLog()
    log.attach(to: grip)

    drag(grip, by: -30)
    drag(grip, by: 12, option: true)

    #expect(
        log.calls == ["begin false", "resize -30.0", "end", "begin true", "resize 12.0", "end"])
}

/// The first click of a double-click starts and ends a drag that moves nothing; the second fits.
@MainActor @Test func aDoubleClickFitsAndOptionFitsEveryColumn() {
    let grip = ColumnGripView(
        frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 400))
    let log = GripLog()
    log.attach(to: grip)

    doubleClick(grip)
    doubleClick(grip, option: true)

    #expect(
        log.calls == ["begin false", "end", "fit false", "begin true", "end", "fit true"])
}

/// A pixel scroll event of `dx` and `dy` points, in a gesture's `phase` or its momentum's, as a
/// trackpad sends it; with neither, a mouse wheel's click.
@MainActor
func scrollEvent(
    dx: Int32 = 0, dy: Int32 = 0, phase: CGScrollPhase? = nil,
    momentum: CGMomentumScrollPhase? = nil
) throws -> NSEvent {
    let cgEvent = try #require(
        CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx,
            wheel3: 0))
    if let phase {
        cgEvent.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
    }
    if let momentum {
        cgEvent.setIntegerValueField(
            .scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
    }
    if phase != nil || momentum != nil {
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    }
    return try #require(NSEvent(cgEvent: cgEvent))
}

/// A view that records the scroll events it gets, as their vertical deltas.
@MainActor
private final class ScrollLog: NSView {
    var deltas: [Double] = []
    override func scrollWheel(with event: NSEvent) { deltas.append(event.scrollingDeltaY) }
}

/// Vertical scrolling over the grip goes to the column under it, as if the grip weren't there;
/// horizontal scrolling goes up to the columns' scroll view, as anywhere over the columns. A
/// trackpad gesture goes to one of them from its first move through its momentum.
@MainActor @Test func aVerticalScrollGoesToTheColumnUnderTheGrip() throws {
    let columns = ScrollLog()
    let column = ScrollLog()
    let grip = ColumnGripView(
        frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 40))
    columns.addSubview(grip)
    grip.scrollTarget = { _ in column }

    // A vertical gesture, which drifts sideways once it moves.
    for event in [
        try scrollEvent(phase: .mayBegin), try scrollEvent(dy: 10, phase: .began),
        try scrollEvent(dx: 8, dy: 2, phase: .changed), try scrollEvent(phase: .ended),
        try scrollEvent(dy: 6, momentum: .begin), try scrollEvent(dy: 3, momentum: .continuous),
        try scrollEvent(momentum: .end),
    ] {
        grip.scrollWheel(with: event)
    }
    #expect(column.deltas == [10, 2, 0, 6, 3, 0])
    #expect(columns.deltas == [0])

    // A horizontal one.
    columns.deltas = []
    column.deltas = []
    for event in [
        try scrollEvent(dx: 10, phase: .began), try scrollEvent(dx: 1, dy: 7, phase: .changed),
        try scrollEvent(phase: .ended),
    ] {
        grip.scrollWheel(with: event)
    }
    #expect(columns.deltas == [0, 7, 0])
    #expect(column.deltas.isEmpty)

    // A mouse wheel's clicks, each on its own.
    columns.deltas = []
    grip.scrollWheel(with: try scrollEvent(dy: 4))
    grip.scrollWheel(with: try scrollEvent(dx: 4))
    #expect(column.deltas == [4])
    #expect(columns.deltas == [0])
}

/// The grip is made 0 points tall and laid out later; its cursor rect, the pointer's
/// `resizeLeftRight`, is reset for every new size, so it covers the grip's full height.
@MainActor @Test func theCursorRectFollowsTheGripsSize() throws {
    let window = CursorRectLog(
        contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: .borderless,
        backing: .buffered, defer: true)
    let grip = ColumnGripView(frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 0))
    try #require(window.contentView).addSubview(grip)
    window.invalidated = []

    grip.frame = NSRect(x: 10, y: 0, width: ColumnGripView.thickness, height: 100)

    #expect(window.invalidated.contains { $0 === grip })
}

/// A window, never shown, that records the views whose cursor rects it was told to reset.
@MainActor
private final class CursorRectLog: NSWindow {
    var invalidated: [NSView] = []
    override func invalidateCursorRects(for view: NSView) {
        invalidated.append(view)
        super.invalidateCursorRects(for: view)
    }
}

/// As in Finder, the grip draws no "||" handle and doesn't cover the separator: every pixel it
/// draws is clear, so the separator line under it shows.
@MainActor @Test func theGripDrawsNothing() throws {
    let grip = ColumnGripView(
        frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 40))
    let bitmap = try #require(grip.bitmapImageRepForCachingDisplay(in: grip.bounds))

    grip.cacheDisplay(in: grip.bounds, to: bitmap)

    #expect(!grip.isOpaque)
    let painted = (0..<bitmap.pixelsWide).flatMap { x in
        (0..<bitmap.pixelsHigh).filter { y in bitmap.colorAt(x: x, y: y)?.alphaComponent != 0 }
    }
    #expect(painted.isEmpty)
}

@MainActor @Test func theGripIsASplitterWhoseValueIsTheWidth() {
    let grip = ColumnGripView(
        frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 400))
    let log = GripLog()
    log.attach(to: grip)
    grip.setAccessibilityLabel(ColumnGripView.label(forColumnNamed: "docs"))

    #expect(grip.isAccessibilityElement())
    #expect(grip.accessibilityRole() == .splitter)
    #expect(grip.accessibilityOrientation() == .vertical)
    #expect(grip.accessibilityLabel() == "docs column width")
    #expect(grip.accessibilityValue() as? NSNumber == 286)
    #expect(grip.accessibilityValueDescription() == "286 points")

    #expect(grip.accessibilityPerformIncrement())
    #expect(log.width == 286 + ColumnGripView.accessibilityStep)
    #expect(grip.accessibilityPerformDecrement())
    #expect(log.width == 286)
    grip.setAccessibilityValue(NSNumber(value: 300))
    #expect(log.width == 300)
}

/// A width that isn't a finite number stops the app, as a value of the wrong type does, rather
/// than lay the columns out at NaN.
@Test func aWidthThatIsNotFiniteFailsLoudly() async {
    await #expect(processExitsWith: .failure) {
        await MainActor.run {
            let grip = ColumnGripView(
                frame: NSRect(x: 0, y: 0, width: ColumnGripView.thickness, height: 400))
            grip.setAccessibilityValue(NSNumber(value: Double.nan))
        }
    }
}
