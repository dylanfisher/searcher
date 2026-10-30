import AppKit
import Testing

@testable import Interface

/// A strip 400 points wide showing `titles` with the one at `selected` selected, laid out.
@MainActor
private func strip(_ titles: [String] = ["root", "other"], selected: Int = 1) -> TabStripView {
    let strip = TabStripView(frame: NSRect(x: 0, y: 0, width: 400, height: TabStripView.height))
    strip.show(titles: titles, selected: selected)
    strip.layoutSubtreeIfNeeded()
    return strip
}

@MainActor private func enterExit(_ type: NSEvent.EventType) throws -> NSEvent {
    try #require(
        NSEvent.enterExitEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
}

/// `color` in sRGB as it resolves in `appearance`.
@MainActor private func resolved(_ color: NSColor, in appearance: NSAppearance.Name) throws
    -> NSColor
{
    var result: NSColor?
    try #require(NSAppearance(named: appearance)).performAsCurrentDrawingAppearance {
        result = color.usingColorSpace(.sRGB)
    }
    return try #require(result)
}

/// The gray that `color` leaves when drawn over the gray `under`.
@MainActor private func over(_ color: NSColor, _ under: CGFloat) -> CGFloat {
    color.redComponent * color.alphaComponent + under * (1 - color.alphaComponent)
}

private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

/// Finder's macOS 26 strip (tmp/shots/fb-1029c-1.jpg): a fully rounded 28 pt track, each tab a
/// segment of it, and the selected tab a fully rounded pill 2 pt inside its segment.
@MainActor @Test func theSelectedTabIsAPillInsetInTheTrack() {
    let strip = strip()

    let track = strip.trackRect
    #expect(track == NSRect(x: 6, y: 3, width: 388, height: 28))
    let selected = strip.tabs[1]
    #expect(selected.frame == NSRect(x: 200, y: 3, width: 194, height: 28))
    #expect(strip.tabs[0].frame == NSRect(x: 6, y: 3, width: 194, height: 28))
    #expect(selected.pillRect == NSRect(x: 2, y: 2, width: 190, height: 24))
    #expect(TabStripView.trackRadius == 14)
    #expect(TabStripView.pillRadius == 12)
    #expect(selected.fill == TabStripView.pillColor)
    #expect(strip.tabs[0].fill == nil)
}

@MainActor @Test func theTabsShareTheTrackEquallyAndTruncateTheirTitles() {
    let strip = strip(["a", "b", "c", "d"], selected: 0)

    #expect(strip.tabs.map(\.frame.width) == [97, 97, 97, 97])
    #expect(strip.tabs.last?.frame.maxX == strip.trackRect.maxX)
    #expect(strip.tabs[0].titleRect.width < strip.tabs[0].pillRect.width)
}

/// The title takes the whole segment but a margin while the close button is hidden, and gives
/// the close button its room at both ends while the mouse is over the tab, as Finder's does.
@MainActor @Test func theTitleMakesRoomForTheCloseButtonOnlyUnderTheMouse() throws {
    let tab = strip().tabs[0]
    let room = TabStripView.closeInset + TabStripView.closeSide + 4

    #expect(tab.titleRect.minX == TabStripView.titleMargin)
    #expect(tab.titleRect.width == tab.bounds.width - 2 * TabStripView.titleMargin)
    tab.mouseEntered(with: try enterExit(.mouseEntered))
    #expect(tab.titleRect.minX == room)
    #expect(tab.titleRect.width == tab.bounds.width - 2 * room)
}

/// Nothing in the strip takes the accent color: every color is a gray in light and dark, and
/// none is one of the accent's colors.
@MainActor @Test func theStripUsesNoAccentColor() throws {
    let strip = strip()
    let accents: [NSColor] = [
        .controlAccentColor, .selectedContentBackgroundColor,
        .selectedControlColor, .keyboardFocusIndicatorColor,
    ]
    let colors =
        [
            TabStripView.trackColor, TabStripView.pillColor, TabStripView.hoverFill,
            TabStripView.pressedFill,
        ] + strip.tabs.map(\.titleColor)
    for color in colors {
        #expect(!accents.contains(color))
        for appearance in appearances {
            let gray = try resolved(color, in: appearance)
            #expect(abs(gray.redComponent - gray.greenComponent) < 0.01)
            #expect(abs(gray.greenComponent - gray.blueComponent) < 0.01)
        }
    }
    #expect(strip.tabs[1].titleColor == .labelColor)
    #expect(strip.tabs[0].titleColor == .secondaryLabelColor)
}

/// The track stands apart from the window behind it, darker in light and lighter in dark, and
/// the pill is lighter than the track in both, so the track shows around the pill.
@MainActor @Test func thePillIsLighterThanTheTrackInLightAndDark() throws {
    for (appearance, window) in [(NSAppearance.Name.aqua, 0.96), (.darkAqua, 0.17)] {
        let track = over(try resolved(TabStripView.trackColor, in: appearance), window)
        let pill = over(try resolved(TabStripView.pillColor, in: appearance), track)
        #expect(abs(track - window) > 0.03, "\(appearance)")
        #expect((track < window) == (appearance == .aqua), "\(appearance)")
        #expect(pill > track + 0.05, "\(appearance)")
    }
}

@MainActor @Test func anUnselectedTabShowsAHoverAndAPressedFill() throws {
    let tab = strip().tabs[0]
    #expect(
        tab.trackingAreas.contains {
            $0.owner === tab && $0.options.contains(.mouseEnteredAndExited)
        })

    tab.mouseEntered(with: try enterExit(.mouseEntered))
    #expect(tab.fill == TabStripView.hoverFill)
    tab.isHighlighted = true
    #expect(tab.fill == TabStripView.pressedFill)
    tab.isHighlighted = false
    tab.mouseExited(with: try enterExit(.mouseExited))
    #expect(tab.fill == nil)
}

@MainActor @Test func theSelectedTabKeepsItsPillUnderTheMouse() throws {
    let tab = strip().tabs[1]

    tab.mouseEntered(with: try enterExit(.mouseEntered))

    #expect(tab.fill == TabStripView.pillColor)
}

/// The close button shows only while the mouse is over its tab, and takes a darker circle
/// under the mouse and a darker one still while pressed.
@MainActor @Test func theCloseButtonShowsOnHoverAndDarkensOverTheX() throws {
    let strip = strip()
    for tab in strip.tabs {
        let close = tab.closeButton
        #expect(close.isHidden)

        tab.mouseEntered(with: try enterExit(.mouseEntered))
        #expect(!close.isHidden)
        #expect(close.fill == nil)
        close.mouseEntered(with: try enterExit(.mouseEntered))
        #expect(close.fill == HoverButton.hoverFill)
        close.isHighlighted = true
        #expect(close.fill == HoverButton.pressedFill)
        close.isHighlighted = false

        tab.mouseExited(with: try enterExit(.mouseExited))
        #expect(close.isHidden)
    }
}

@MainActor @Test func theCloseButtonIsARoundButtonAtTheTabsLeadingEnd() {
    let tab = strip().tabs[0]
    tab.layoutSubtreeIfNeeded()

    let close = tab.closeButton
    #expect(close.isRound)
    #expect(close.frame.width == TabStripView.closeSide)
    #expect(close.frame.minX == TabStripView.closeInset)
    #expect(close.frame.midY == tab.bounds.midY)
    #expect(close.accessibilityLabel() == "Close Tab")
}

@MainActor @Test func clickingTheCloseButtonReportsItsTab() throws {
    let strip = strip()
    var closed: [Int] = []
    strip.onClose = { closed.append($0) }

    strip.tabs[0].mouseEntered(with: try enterExit(.mouseEntered))
    let close = strip.tabs[0].closeButton
    #expect(
        NSApplication.shared.sendAction(try #require(close.action), to: close.target, from: close))

    #expect(closed == [0])
}

/// The focus ring, which the system draws while a tab has the keys with keyboard navigation
/// on, takes the pill's shape.
@MainActor @Test func theFocusRingTakesThePillsShape() {
    let tab = strip().tabs[0]

    #expect(tab.focusRingMaskBounds == tab.pillRect)
}

@MainActor @Test func eachTabIsARadioButtonThatCanBeClosedByVoiceOver() throws {
    let strip = strip()

    #expect(strip.accessibilityRole() == .tabGroup)
    #expect(strip.tabs.map { $0.accessibilityRole() } == [.radioButton, .radioButton])
    #expect(strip.tabs.map { $0.accessibilityLabel() } == ["root", "other"])
    #expect(strip.tabs.map { $0.accessibilityValue() as? Bool } == [false, true])
    let action = try #require(strip.tabs[0].accessibilityCustomActions()?.first)
    var closed: [Int] = []
    strip.onClose = { closed.append($0) }
    #expect(action.name == "Close Tab")
    #expect(action.handler?() == true)
    #expect(closed == [0])
}
