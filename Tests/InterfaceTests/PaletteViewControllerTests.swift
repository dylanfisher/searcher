import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

/// A source that hands over fixed items on every key.
@MainActor
private struct FixedSource: PaletteSource {
    let items: [PaletteItem]

    func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        deliver(items)
    }

    func cancel() {}
}

/// A palette over `folders`, "Downloads" and "Documents" unless given, and the commands New Tab
/// and Open Quickly, in a view that is never shown, with what ran and the beeps counted. New Tab is off
/// while `newTabIsOff`.
@MainActor
private final class Fixture {
    let ran = EventLog<String>()
    let window = KeyCatchingWindow()
    let controller: PaletteViewController
    var closes = 0
    var beeps = 0
    var newTabIsOff = false

    init(folders: [String] = ["Downloads", "Documents"]) {
        let ran = ran
        func folder(_ name: String) -> PaletteItem {
            PaletteItem(id: .folder(path: "/Users/me/\(name)"), title: name) { ran.append(name) }
        }
        func command(_ command: Command) -> PaletteItem {
            PaletteItem(
                id: .command(command.id), title: command.title, chord: command.chords.first
            ) { ran.append(command.title) }
        }
        let palette = Palette(sources: [
            FixedSource(items: folders.map(folder)),
            FixedSource(items: [
                command(WindowCommands.newTab), command(WindowCommands.showPalette),
            ]),
        ])
        controller = PaletteViewController(palette: palette)
        controller.isEnabled = { [unowned self] item in
            item.id != .command(WindowCommands.newTab.id) || !newTabIsOff
        }
        controller.onClose = { [unowned self] in closes += 1 }
        controller.beep = { [unowned self] in beeps += 1 }
        window.contentView = controller.view
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(controller.field)
    }

    /// The field's editor, which has the keys.
    var editor: NSTextView {
        get throws {
            let editor = try #require(window.firstResponder as? NSTextView)
            #expect(editor.isFieldEditor)
            return editor
        }
    }

    /// Replaces the field's text with `query`, as typing would, and waits until its rows show.
    func type(_ query: String) async throws {
        let editor = try editor
        editor.insertText(
            query, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        await settle { controller.shownQuery == query }
    }

    func press(_ characters: String, keyCode: UInt16 = 0, modifiers: NSEvent.ModifierFlags = [])
        throws
    {
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
        try editor.keyDown(with: event)
    }

    var titles: [String] {
        (0..<controller.tableView.numberOfRows).map { cell(at: $0)?.titleField.stringValue ?? "" }
    }

    func cell(at row: Int) -> PaletteCellView? {
        controller.tableView.view(atColumn: 0, row: row, makeIfNecessary: true)
            as? PaletteCellView
    }

    func row(titled title: String) throws -> Int {
        try #require(titles.firstIndex(of: title), "no row \(title) in \(titles)")
    }
}

/// Whether the title's letter at `offset` is drawn bold.
@MainActor
private func isBold(_ title: NSAttributedString, at offset: Int) -> Bool {
    let font = title.attribute(.font, at: offset, effectiveRange: nil) as? NSFont
    return font?.fontDescriptor.symbolicTraits.contains(.bold) == true
}

@MainActor @Test func dlShowsDownloadsFirstWithItsMatchedLettersBold() async throws {
    let fixture = Fixture()

    try await fixture.type("dl")

    #expect(fixture.titles.first == "Downloads")
    let title = try #require(fixture.cell(at: 0)?.titleField.attributedStringValue)
    let bold = (0..<title.length).filter { isBold(title, at: $0) }
    // D and the l of "Downloads".
    #expect(bold == [0, 4])
    #expect(fixture.controller.tableView.selectedRow == 0)
}

@MainActor @Test func downThenReturnRunsTheSecondItemAndClosesFirst() async throws {
    let fixture = Fixture()
    try await fixture.type("do")
    let second = fixture.titles[1]

    try fixture.press(functionKey(NSDownArrowFunctionKey), keyCode: 125, modifiers: arrowFlags)
    #expect(fixture.controller.tableView.selectedRow == 1)
    try fixture.press("\r", keyCode: 36)

    #expect(fixture.ran.all == [second])
    #expect(fixture.closes == 1)
    #expect(fixture.window.unhandledCommands.isEmpty && fixture.window.unhandledKeys.isEmpty)
}

@MainActor @Test func upAtTheTopStaysOnTheFirstRow() async throws {
    let fixture = Fixture()
    try await fixture.type("do")

    try fixture.press(functionKey(NSUpArrowFunctionKey), keyCode: 126, modifiers: arrowFlags)

    #expect(fixture.controller.tableView.selectedRow == 0)
}

@MainActor @Test func escClosesWithoutRunningAnything() async throws {
    let fixture = Fixture()
    try await fixture.type("dl")

    try fixture.press("\u{1B}", keyCode: 53)

    #expect(fixture.closes == 1)
    #expect(fixture.ran.all.isEmpty)
}

@MainActor @Test func aCommandItemShowsItsChordRightOfItsTitle() async throws {
    let fixture = Fixture()
    try await fixture.type("new tab")

    let cell = try #require(fixture.cell(at: fixture.row(titled: "New Tab")))
    #expect(cell.chordField.stringValue == "⌘T")
    #expect(!cell.chordField.isHidden)
    try await fixture.type("")
    let folder = try #require(fixture.cell(at: fixture.row(titled: "Downloads")))
    #expect(folder.chordField.isHidden)
}

@MainActor @Test func anOffCommandIsGreyedAndReturnBeepsWithoutRunningIt() async throws {
    let fixture = Fixture()
    fixture.newTabIsOff = true
    // An empty query lists the folders, then the commands.
    try await fixture.type("")
    let row = try fixture.row(titled: "New Tab")
    #expect(row == 2)
    let cell = try #require(fixture.cell(at: row))
    #expect(!cell.isEnabled)
    #expect(cell.titleField.textColor == .tertiaryLabelColor)

    for _ in 0..<row {
        try fixture.press(functionKey(NSDownArrowFunctionKey), keyCode: 125, modifiers: arrowFlags)
    }
    try fixture.press("\r", keyCode: 36)

    #expect(fixture.ran.all.isEmpty)
    #expect(fixture.beeps == 1)
    #expect(fixture.closes == 0)
}

@MainActor @Test func cmdAInTheFieldSelectsItsText() async throws {
    let fixture = Fixture()
    try await fixture.type("downloads")
    NSMenuItem.usesUserKeyEquivalents = false
    let menu = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let selectAll = try #require(
        menu.items.flatMap { $0.submenu?.items ?? [] }.first { $0.title == "Select All" })
    let editor = try fixture.editor
    editor.setSelectedRange(NSRange(location: 3, length: 0))

    // The menu item the key triggers goes to the field's editor, the first that answers it.
    #expect(editor.tryToPerform(try #require(selectAll.action), with: selectAll))

    #expect(try fixture.editor.selectedRange() == NSRange(location: 0, length: 9))
    #expect(fixture.ran.all.isEmpty && fixture.closes == 0)
}

@MainActor @Test func theFieldAndRowsAreLabelledWithTitleAndKind() async throws {
    let fixture = Fixture()
    fixture.newTabIsOff = true
    try await fixture.type("d")

    #expect(fixture.controller.field.accessibilityLabel() != nil)
    let folder = try #require(fixture.cell(at: fixture.row(titled: "Downloads")))
    #expect(folder.accessibilityLabel() == "Downloads, folder")
    try await fixture.type("new")
    let command = try #require(fixture.cell(at: fixture.row(titled: "New Tab")))
    #expect(command.accessibilityLabel() == "New Tab, command, ⌘T, unavailable")
}

@MainActor @Test func aHomePathTitleAndAnAccentedTitleBoldTheLettersMatched() async throws {
    let fixture = Fixture(folders: ["~/Projects", "Résumés"])

    try await fixture.type("pr")
    let path = try #require(fixture.cell(at: fixture.row(titled: "~/Projects")))
    let pathTitle = path.titleField.attributedStringValue
    #expect((0..<pathTitle.length).filter { isBold(pathTitle, at: $0) } == [2, 3])

    // "e" matches "é".
    try await fixture.type("res")
    let accented = try #require(fixture.cell(at: fixture.row(titled: "Résumés")))
    let accentedTitle = accented.titleField.attributedStringValue
    #expect((0..<accentedTitle.length).filter { isBold(accentedTitle, at: $0) } == [0, 1, 2])
}

@MainActor @Test func optionAndShiftReturnRunTheSelectedItemAsReturnDoes() async throws {
    for modifiers: NSEvent.ModifierFlags in [.option, .shift] {
        let fixture = Fixture()
        try await fixture.type("dl")

        try fixture.press("\r", keyCode: 36, modifiers: modifiers)

        #expect(fixture.ran.all == ["Downloads"], "\(modifiers)")
        #expect(fixture.beeps == 0)
        #expect(fixture.window.unhandledCommands.isEmpty && fixture.window.unhandledKeys.isEmpty)
    }
}

@MainActor @Test func aCommandKeyTheFieldDoesntUseDoesNothing() async throws {
    let fixture = Fixture()
    try await fixture.type("dl")

    try fixture.press("t", keyCode: 17, modifiers: .command)

    #expect(fixture.window.unhandledCommands.isEmpty && fixture.window.unhandledKeys.isEmpty)
    #expect(try fixture.editor.string == "dl")
    #expect(fixture.ran.all.isEmpty && fixture.closes == 0)
}

@MainActor @Test func theContentIsLiquidGlassFromMacOS26AndABlurBefore() {
    let controller = PaletteWindowController(
        palette: Palette(sources: []), settings: untouchedSettings())
    let backdrop = controller.viewController.view.subviews.first
    let radius = PaletteViewController.cornerRadius

    if #available(macOS 26, *) {
        let glass = backdrop as? NSGlassEffectView
        #expect(glass != nil)
        #expect(glass?.cornerRadius == radius)
        #expect(glass?.contentView?.subviews.contains(controller.viewController.field) == true)
    } else {
        let blur = backdrop as? NSVisualEffectView
        #expect(blur?.material == .popover)
        #expect(blur?.blendingMode == .behindWindow)
        #expect(blur?.state == .active)
        #expect(blur?.maskImage?.capInsets.top == radius)
        #expect(blur?.maskImage?.capInsets.left == radius)
        #expect(blur?.maskImage?.resizingMode == .stretch)
    }
}

@MainActor @Test func nothingBetweenTheBackdropAndTheDesktopPaintsAnOpaqueBackground() throws {
    let controller = PaletteWindowController(
        palette: Palette(sources: []), settings: untouchedSettings())
    let palette = controller.viewController
    let scrollView = try #require(palette.tableView.enclosingScrollView)

    #expect(scrollView.drawsBackground == false)
    #expect(scrollView.contentView.drawsBackground == false)
    #expect(palette.tableView.backgroundColor == .clear)
    #expect(palette.field.drawsBackground == false)
    #expect(palette.view.layer?.backgroundColor?.alpha ?? 0 == 0)
}

@MainActor @Test func thePanelIsBorderlessClearAndShadowed() throws {
    let controller = PaletteWindowController(
        palette: Palette(sources: []), settings: untouchedSettings())
    let panel = try #require(controller.window)

    #expect(panel.styleMask.contains(.titled) == false)
    #expect(panel.isOpaque == false)
    #expect(panel.backgroundColor == .clear)
    #expect(panel.canBecomeKey)
}

@MainActor @Test func thePanelIsDraggedByItsBackgroundAndJoinsTheSpaceShowing() throws {
    let controller = PaletteWindowController(
        palette: Palette(sources: []), settings: untouchedSettings())
    let panel = try #require(controller.window)

    #expect(panel.isMovable)
    #expect(panel.isMovableByWindowBackground)
    // Beside the magnifying glass, a click lands on the background, which moves the window.
    let content = controller.viewController.view
    content.layoutSubtreeIfNeeded()
    let hit = content.hitTest(NSPoint(x: 10, y: content.bounds.height - 30))
    #expect(hit != nil)
    #expect(hit?.mouseDownCanMoveWindow == true)
    let field = controller.viewController.field
    #expect(content.hitTest(field.convert(NSPoint(x: 20, y: 10), to: content)) != nil)
    #expect(field.mouseDownCanMoveWindow == false)
    #expect(panel.collectionBehavior.contains(.moveToActiveSpace))
    #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
}

@MainActor
private var paletteSize: NSSize {
    NSSize(width: PaletteViewController.width, height: PaletteViewController.height)
}

@MainActor @Test func withNoPlaceThePanelIsCenteredAcrossTheScreenInItsUpperPart() {
    let visible = NSRect(x: -1600, y: 40, width: 1600, height: 1000)

    let frame = PaletteWindowController.frame(size: paletteSize, on: visible, at: nil)

    #expect(frame.size == paletteSize)
    #expect(frame.midX == visible.midX)
    #expect(frame.maxY == visible.maxY - 1000 * PaletteWindowController.topShare)
}

@MainActor @Test func withNoPlaceOnAShortScreenThePanelKeepsItsBottomOnIt() {
    let visible = NSRect(x: 0, y: 0, width: 1024, height: 400)

    let frame = PaletteWindowController.frame(size: paletteSize, on: visible, at: nil)

    #expect(frame.minY == visible.minY)
}

@MainActor @Test func aPlacePutsThePanelThatShareOfTheRoomItLeaves() throws {
    let visible = NSRect(x: 100, y: 50, width: 1640, height: 1361)
    func frame(_ x: Double, _ y: Double) throws -> NSRect {
        let place = try #require(Settings.PalettePlace(x: x, y: y))
        return PaletteWindowController.frame(size: paletteSize, on: visible, at: place)
    }

    #expect(try frame(0, 0).origin == NSPoint(x: 100, y: 1411 - paletteSize.height))
    #expect(try frame(1, 1).origin == NSPoint(x: 1740 - paletteSize.width, y: 50))
    #expect(try frame(0.5, 0.5).origin == NSPoint(x: 600, y: 550))
}

@MainActor @Test func thePlaceOfAFrameReadsBackAsThatFrameAndOnePastAnEdgeIsPutAgainstIt() throws {
    let visible = NSRect(x: 100, y: 50, width: 1640, height: 1361)
    let place = try #require(Settings.PalettePlace(x: 0.3, y: 0.8))
    let frame = PaletteWindowController.frame(size: paletteSize, on: visible, at: place)

    #expect(PaletteWindowController.place(of: frame, on: visible) == place)
    let pastTopRight = NSRect(origin: NSPoint(x: 2000, y: 1500), size: paletteSize)
    #expect(
        PaletteWindowController.place(of: pastTopRight, on: visible)
            == Settings.PalettePlace(x: 1, y: 0))
}

/// A palette over a window that is never shown, which puts its panel where it would show.
@MainActor
private func paletteShown(with settings: Settings) throws -> PaletteWindowController {
    let controller = PaletteWindowController(palette: Palette(sources: []), settings: settings)
    let opener = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
        backing: .buffered, defer: true)
    opener.isReleasedWhenClosed = false
    controller.show(over: opener)
    return controller
}

@MainActor @Test func aDraggedPanelLeavesItsPlaceForTheNextPalette() throws {
    let settings = untouchedSettings()
    let first = try paletteShown(with: settings)
    let panel = try #require(first.window)
    let dragged = panel.frame.offsetBy(dx: -120, dy: -80)
    panel.setFrame(dragged, display: false)

    first.close()

    #expect(settings.palettePlace != nil)
    let next = try #require(try paletteShown(with: settings).window)
    #expect(abs(next.frame.minX - dragged.minX) < 0.01)
    #expect(abs(next.frame.minY - dragged.minY) < 0.01)
}

@MainActor @Test func aPanelThatWasntDraggedLeavesTheStoredPlaceAlone() throws {
    let settings = untouchedSettings()
    let controller = try paletteShown(with: settings)

    controller.close()

    #expect(settings.palettePlace == nil)
}

@MainActor @Test func aPanelDraggedOffEveryScreenGoesBackToItsOwnPlace() throws {
    let settings = untouchedSettings()
    settings.palettePlace = Settings.PalettePlace(x: 0, y: 0)
    let controller = try paletteShown(with: settings)
    let panel = try #require(controller.window)
    let screens = NSScreen.screens.map(\.frame).reduce(NSRect.null) { $0.union($1) }
    panel.setFrameOrigin(NSPoint(x: screens.maxX + 1000, y: screens.maxY + 1000))

    controller.close()

    #expect(settings.palettePlace == nil)
}

/// On screen, the panel is a window of its own on its opener's screen, not a child that moves
/// with it. Only with a second display, where test windows go
/// (docs/decisions/0091-test-windows-on-second-display.md).
@MainActor @Test func thePanelShowsOnItsOpenersScreenAsAWindowOfItsOwn() async throws {
    guard NSScreen.screens.count > 1 else { return }
    let opener = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
        backing: .buffered, defer: false)
    opener.isReleasedWhenClosed = false
    SecondDisplay.orderFront(opener)
    defer { opener.orderOut(nil) }
    let screen = try #require(opener.screen)
    let controller = PaletteWindowController(
        palette: Palette(sources: []), settings: untouchedSettings())
    let panel = try #require(controller.window)

    controller.show(over: opener)
    defer { controller.close() }

    #expect(panel.isVisible)
    #expect(panel.parent == nil)
    #expect(opener.childWindows?.isEmpty ?? true)
    #expect(panel.screen == screen)
    #expect(panel.frame.midX == screen.visibleFrame.midX)
}

/// The glass draws a faint fill over its whole rectangle while the app is active; the content
/// clips it to the rounded shape, so the corners stay clear and the window's shadow, shaped from
/// the window's pixels, is rounded (docs/decisions/0087).
@MainActor @Test func theContentIsClippedToTheRoundedShapeUnderAHairlineAndShadowed() throws {
    let controller = PaletteWindowController(
        palette: Palette(sources: []), settings: untouchedSettings())
    let panel = try #require(controller.window)
    let content = controller.viewController.view
    let radius = PaletteViewController.cornerRadius

    #expect(panel.hasShadow)
    #expect(content.layer?.masksToBounds == true)
    #expect(content.layer?.cornerRadius == radius)
    let edge = try #require(content.subviews.last as? PaletteEdgeView)
    #expect(edge.frame == content.bounds)
    edge.updateLayer()
    #expect(edge.layer?.cornerRadius == radius)
    #expect((edge.layer?.borderWidth ?? 0) > 0)
    #expect((edge.layer?.borderColor?.alpha ?? 0) > 0)
    #expect(edge.hitTest(NSPoint(x: 1, y: 1)) == nil)
}

/// A name too long for one line wraps; its row grows to hold the lines, with room between them
/// and around them, and a row whose title fits keeps its height.
@MainActor @Test func aLongTitleWrapsInATallerRowWithRoomBetweenAndAroundItsLines() async throws {
    let long =
        "Quarterly report for the northern region including every appendix and the revised "
        + "figures from March, final version two.pdf"
    let fixture = Fixture(folders: ["Downloads", long])
    try await fixture.type("")
    let table = fixture.controller.tableView
    let short = try fixture.row(titled: "Downloads")
    let wrapped = try fixture.row(titled: long)
    table.layoutSubtreeIfNeeded()

    #expect(table.rect(ofRow: short).height == PaletteCellView.rowHeight)
    let cell = try #require(fixture.cell(at: wrapped))
    cell.layoutSubtreeIfNeeded()
    let title = cell.titleField
    let font = try #require(title.font)
    let line = (font.ascender - font.descender + font.leading).rounded(.up)
    let style = try #require(
        title.attributedStringValue.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle)
    #expect(style.lineSpacing >= 3)
    #expect(title.frame.height >= 2 * line + style.lineSpacing)
    #expect(title.frame.minY >= PaletteCellView.wrappedPadding - 0.5)
    #expect(cell.bounds.height - title.frame.maxY >= PaletteCellView.wrappedPadding - 0.5)
    #expect(table.rect(ofRow: wrapped).height == cell.bounds.height)
    // A title on one line is as tall as a plain label: the line spacing adds nothing to it.
    let shortTitle = try #require(fixture.cell(at: short)?.titleField)
    let unspaced = NSMutableAttributedString(attributedString: shortTitle.attributedStringValue)
    unspaced.removeAttribute(.paragraphStyle, range: NSRange(location: 0, length: unspaced.length))
    let plain = NSTextField(labelWithAttributedString: unspaced)
    #expect(shortTitle.frame.height == plain.intrinsicContentSize.height)
}

@MainActor @Test func theSearchFieldIsLargerThanTheRows() {
    let controller = PaletteWindowController(
        palette: Palette(sources: []), settings: untouchedSettings())
    _ = controller.viewController.view

    #expect((controller.viewController.field.font?.pointSize ?? 0) >= 24)
}
