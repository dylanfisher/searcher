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
