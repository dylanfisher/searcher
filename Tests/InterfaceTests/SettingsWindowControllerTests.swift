import AppKit
import Browser
import Testing

@testable import Interface

private let cmdP = KeyChord("p", modifiers: .command)
private let cmdC = KeyChord("c", modifiers: .command)
private let palette = WindowCommands.showPalette
private let goToItem = WindowCommands.goToItem

/// A controller over settings of its own that never shows its window, and the windows it would
/// have brought forward.
@MainActor
private func controller(
    _ settings: Settings = untouchedSettings()
) -> (SettingsWindowController, () -> [NSWindow]) {
    let controller = SettingsWindowController(settings: settings)
    var shown: [NSWindow] = []
    controller.bringForward = { shown.append($0) }
    return (controller, { shown })
}

/// App ▸ Settings… a second time brings the same window forward, not a second one.
@MainActor @Test func showingTwiceBringsOneWindowForward() throws {
    let (controller, shown) = controller()

    controller.show()
    controller.show()

    let window = try #require(controller.window)
    #expect(shown().count == 2)
    #expect(shown().allSatisfy { $0 === window })
    #expect(window.toolbar?.selectedItemIdentifier?.rawValue == "shortcuts")
    #expect(!window.isVisible)
}

/// Every registered command has one row, under its menu, with the registry's title and chords.
@MainActor @Test func theRowsComeFromTheRegistryGroupedAsTheMenus() throws {
    let (controller, _) = controller()
    let model = controller.shortcuts
    let bindings = PaneViewController.keyBindings(for: model.settings)

    let rows = model.sections.flatMap(\.rows)

    #expect(model.sections.map(\.title) == ["File", "Edit", "Go", "View", "Window"])
    #expect(rows.count == AppCommands.commands.count)
    #expect(Set(rows.map(\.id)) == Set(AppCommands.commands.map(\.id)))
    for row in rows {
        #expect(row.title == bindings.registry.command(for: row.id)?.title)
        #expect(row.chords == bindings.chords(of: row.id))
        #expect(!row.isChanged)
    }
    let selectNext = try #require(rows.first { $0.id == SelectionCommands.selectNext.id })
    #expect(selectNext.note == ShortcutsSettings.listOnlyNote)
    let copy = try #require(rows.first { $0.id == ClipboardCommands.copy.id })
    #expect(copy.primaryIsFixed)
    let quickLook = try #require(rows.first { $0.id == ViewCommands.toggleQuickLook.id })
    #expect(quickLook.note == ShortcutsSettings.plainKeyNote)
}

@MainActor @Test func searchFiltersByTitleOrChordSymbols() throws {
    let (controller, _) = controller()
    let model = controller.shortcuts

    model.search = "go to item"
    #expect(model.sections.flatMap(\.rows).map(\.id) == [goToItem.id])

    model.search = "⇧⌘P"
    #expect(model.sections.flatMap(\.rows).map(\.id) == [palette.id])

    model.search = "no command is called this"
    #expect(model.sections.isEmpty)
}

/// Recording a chord another command has asks first; Replace takes it, and Cancel leaves both.
@MainActor @Test func replaceMovesTheChordAndCancelLeavesIt() throws {
    let (controller, _) = controller()
    let model = controller.shortcuts

    model.record(.chords([cmdP]), for: palette.id, at: .alternate)

    let notice = try #require(model.notices[palette.id])
    #expect(notice.isConflict)
    #expect(notice.message == "⌘P is used by \(goToItem.title).")
    #expect(model.settings.shortcuts.isEmpty)

    model.cancel(palette.id)
    #expect(model.notices[palette.id] == nil)
    #expect(model.settings.shortcuts.isEmpty)

    model.record(.chords([cmdP]), for: palette.id, at: .alternate)
    model.replace(palette.id)

    #expect(model.notices[palette.id] == nil)
    let bindings = PaneViewController.keyBindings(for: model.settings)
    #expect(bindings.chords(of: palette.id).alternate == cmdP)
    #expect(bindings.chords(of: goToItem.id).primary == nil)
    #expect(bindings.registry.command(for: cmdP)?.id == palette.id)
    #expect(model.bindings.chords(of: palette.id).alternate == cmdP)
}

/// A chord a rule refuses says which rule, and changes nothing.
@MainActor @Test func aFixedOrReservedChordShowsItsMessage() throws {
    let (controller, _) = controller()
    let model = controller.shortcuts

    model.record(.chords([cmdC]), for: palette.id, at: .alternate)
    #expect(model.notices[palette.id]?.kind == .fixed(to: ClipboardCommands.copy))
    #expect(model.notices[palette.id]?.message.contains("Copy") == true)

    model.record(.chords([KeyChord(",", modifiers: .command)]), for: palette.id, at: .primary)
    #expect(model.notices[palette.id]?.kind == .reserved)

    model.record(.removed, for: ClipboardCommands.copy.id, at: .primary)
    #expect(model.notices[ClipboardCommands.copy.id]?.kind == .fixedPrimary)

    #expect(model.settings.shortcuts.isEmpty)
}

@MainActor @Test func resetGivesARowItsDefaultsAndResetAllEveryRow() throws {
    let (controller, _) = controller()
    let model = controller.shortcuts
    let cmdJ = KeyChord("j", modifiers: [.command, .option, .control])
    let cmdL = KeyChord("l", modifiers: [.command, .option, .control])
    #expect(!model.canResetAll)

    model.record(.chords([cmdJ]), for: palette.id, at: .alternate)
    model.record(.chords([cmdL]), for: goToItem.id, at: .alternate)
    model.record(.removed, for: goToItem.id, at: .primary)
    func row(_ id: CommandID) throws -> ShortcutsSettings.Row {
        try #require(model.sections.flatMap(\.rows).first { $0.id == id })
    }
    #expect(try row(palette.id).isChanged)
    #expect(try row(goToItem.id).chords == KeyBindings.Chords(primary: nil, alternate: cmdL))
    #expect(model.canResetAll)

    model.reset(goToItem.id)
    #expect(try !row(goToItem.id).isChanged)
    #expect(try row(goToItem.id).chords.primary == goToItem.primary)
    #expect(try row(palette.id).chords.alternate == cmdJ)

    model.resetAll()
    #expect(model.settings.shortcuts.isEmpty)
    #expect(try row(palette.id).chords.alternate == palette.alternate)
    #expect(!model.canResetAll)
}

/// Cmd-W closes the Settings window, though Close Pane is off outside the panes, and follows
/// Close Pane's chords.
@MainActor @Test func closePanesChordClosesTheWindow() throws {
    let settings = untouchedSettings()
    let (controller, _) = controller(settings)
    let window = try #require(controller.window)
    var closes = 0
    let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: nil
    ) { _ in MainActor.assumeIsolated { closes += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }

    #expect(!window.performKeyEquivalent(with: try keyEvent("j", modifiers: .command)))
    #expect(closes == 0)
    #expect(window.performKeyEquivalent(with: try keyEvent("w", modifiers: .command)))
    #expect(closes == 1)

    // A closed window posts no second close, so the chords are read directly.
    let cmdOptW = KeyChord("w", modifiers: [.command, .option])
    settings.shortcuts = [TilingCommands.closePane.id: ShortcutOverride(alternate: .chord(cmdOptW))]
    let settingsWindow = try #require(window as? SettingsWindow)
    #expect(settingsWindow.closingChords() == [KeyChord("w", modifiers: .command), cmdOptW])
    #expect(window.performKeyEquivalent(with: try keyEvent("w", modifiers: [.command, .option])))
}
