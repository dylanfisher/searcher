import AppKit
import Browser
import TestSupport
import Testing

@testable import Interface

// Each tag dot has a hover, pressed, focused and disabled look
// (docs/decisions/0110-interaction-states.md, docs/decisions/0121-tag-commands.md).

private let red = FinderTag.all[0]

@MainActor
private func enter(_ view: NSView) throws {
    view.mouseEntered(
        with: try #require(
            NSEvent.enterExitEvent(
                with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
}

@MainActor
private func exit(_ view: NSView) throws {
    view.mouseExited(
        with: try #require(
            NSEvent.enterExitEvent(
                with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: 0,
                context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
}

@MainActor @Test func aDotUnderTheMouseShowsWhatAClickDoesAndTheLineSaysIt() throws {
    let view = TagDotsView(isEnabled: { _ in true }, toggle: { _ in })
    view.validate()
    view.show([["Red"], []])
    let dot = try #require(view.dots.first { $0.finderTag == red })
    #expect(dot.mark == .dash)
    #expect(view.line.stringValue == TagDotsView.restTitle)

    try enter(dot)
    #expect(dot.isHovered)
    #expect(dot.mark == .plus)
    #expect(view.line.stringValue == "Add Tag “Red”")

    view.show([["Red"], ["Red"]])
    #expect(dot.mark == .cross)
    #expect(view.line.stringValue == "Remove Tag “Red”")

    try exit(dot)
    #expect(dot.mark == .check)
    #expect(view.line.stringValue == TagDotsView.restTitle)
}

@MainActor @Test func aPressedDotDarkensAndADisabledOneFadesAndShowsNoHover() throws {
    let dot = TagDotButton(red)
    dot.coverage = .noItems
    #expect(dot.fill == dot.color)

    dot.isHighlighted = true
    #expect(dot.fill != dot.color)
    dot.isHighlighted = false

    dot.isEnabled = false
    try enter(dot)
    #expect(dot.fill.alphaComponent == TagDotButton.disabledAlpha)
    #expect(dot.mark == nil)
}

@MainActor @Test func dotsAreOffWhileTheirCommandsCantRunAndOnceTheyCan() throws {
    @MainActor final class Commands {
        var canRun = false
        var toggled: [FinderTag] = []
    }
    let commands = Commands()
    let view = TagDotsView(
        isEnabled: { _ in commands.canRun }, toggle: { commands.toggled.append($0) })

    view.validate()
    #expect(view.dots.allSatisfy { !$0.isEnabled })

    commands.canRun = true
    view.validate()
    #expect(view.dots.allSatisfy { $0.isEnabled })
    let dot = try #require(view.dots.first { $0.finderTag == red })
    // What a mouse-up on the dot sends, through the app, which a test makes first.
    _ = NSApplication.shared
    #expect(dot.sendAction(dot.action, to: dot.target))
    #expect(commands.toggled == [red])
}

@MainActor @Test func eachDotIsAButtonVoiceOverNamesByWhatItDoesAndTakesARoundFocusRing() {
    let dot = TagDotButton(red)
    #expect(dot.accessibilityRole() == .button)
    #expect(dot.accessibilityLabel() == "Red")
    dot.coverage = .allItems
    #expect(dot.accessibilityLabel() == "Remove Tag “Red”")
    #expect(dot.focusRingMaskBounds == dot.bounds)
    #expect(dot.focusRingType != .none)
}

/// A press that reaches a dot turned off since, as a VoiceOver press can, toggles nothing.
@MainActor @Test func aDisabledDotDoesNothing() throws {
    @MainActor final class Commands {
        var toggled: [FinderTag] = []
    }
    let commands = Commands()
    let view = TagDotsView(isEnabled: { _ in false }, toggle: { commands.toggled.append($0) })
    view.validate()
    let dot = try #require(view.dots.first { $0.finderTag == red })
    #expect(!dot.isEnabled)

    _ = NSApplication.shared
    _ = dot.sendAction(dot.action, to: dot.target)

    #expect(commands.toggled.isEmpty)
}

/// A press takes the dot inside its circle, grown, plus a small margin, and not in the
/// button's corners, both as the window finds the view under it and as the cell tracks it.
@MainActor @Test func aPressTakesTheDotInItsCircleAndNotInACorner() throws {
    let window = testWindow(size: NSSize(width: 300, height: 100))
    let view = TagDotsView(isEnabled: { _ in true }, toggle: { _ in })
    window.contentView?.addSubview(view)
    let dot = try #require(view.dots.first { $0.finderTag == red })
    let center = NSPoint(x: dot.bounds.midX, y: dot.bounds.midY)
    let corner = NSPoint(x: dot.bounds.minX + 0.5, y: dot.bounds.minY + 0.5)
    func event(at point: NSPoint) throws -> NSEvent {
        try mouseEvent(.leftMouseDown, at: dot.convert(point, to: nil), in: window)
    }

    #expect(view.hitTest(dot.convert(center, to: view.superview)) === dot)
    #expect(view.hitTest(dot.convert(corner, to: view.superview)) === view)
    let cell = try #require(dot.cell)
    #expect(
        cell.hitTest(for: try event(at: center), in: dot.bounds, of: dot).contains(.contentArea))
    #expect(cell.hitTest(for: try event(at: corner), in: dot.bounds, of: dot).isEmpty)
}

/// A dot whose tag every selected item has shows a check, drawn the right way up: the button is
/// flipped, as `NSButton` is, so its point lies below its two ends on screen.
@MainActor @Test func aDotsCheckPointsDown() {
    let dot = TagDotButton(FinderTag.all[0])
    dot.coverage = .allItems

    let points = dot.checkPoints(in: dot.bounds)

    #expect(dot.isFlipped)
    #expect(points.count == 3)
    // In flipped coordinates the lower point has the larger y.
    #expect(points[1].y > points[0].y)
    #expect(points[1].y > points[2].y)
    #expect(points[2].y < points[0].y)
}
