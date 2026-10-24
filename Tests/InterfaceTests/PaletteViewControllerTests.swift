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

@MainActor @Test func theContentIsAnActiveBehindWindowBlurWithRoundedCorners() {
    let controller = PaletteWindowController(palette: Palette(sources: []))
    let blur = controller.viewController.view as? NSVisualEffectView

    #expect(blur?.material == .popover)
    #expect(blur?.blendingMode == .behindWindow)
    #expect(blur?.state == .active)
    #expect(blur?.wantsLayer == true)
    #expect(blur?.layer?.cornerRadius == PaletteViewController.cornerRadius)
    #expect(blur?.layer?.masksToBounds == true)
}

@MainActor @Test func thePanelIsBorderlessClearAndShadowed() throws {
    let controller = PaletteWindowController(palette: Palette(sources: []))
    let panel = try #require(controller.window)

    #expect(panel.styleMask.contains(.titled) == false)
    #expect(panel.isOpaque == false)
    #expect(panel.backgroundColor == .clear)
    #expect(panel.hasShadow)
    #expect(panel.canBecomeKey)
}

@MainActor @Test func theSearchFieldIsLargerThanTheRows() {
    let controller = PaletteWindowController(palette: Palette(sources: []))
    _ = controller.viewController.view

    #expect((controller.viewController.field.font?.pointSize ?? 0) >= 24)
}
