import AppKit
import Browser
import BrowserTestSupport
import TestSupport
import Testing
import UniformTypeIdentifiers

@testable import Interface

private let cmdP = KeyChord("p", modifiers: .command)
private let cmdC = KeyChord("c", modifiers: .command)
private let palette = WindowCommands.showPalette
private let goToItem = WindowCommands.goToItem

/// A controller over settings of its own that never shows its window or posts to VoiceOver, and
/// the windows it would have brought forward.
@MainActor
private func controller(
    _ settings: Settings = untouchedSettings(), loginItem: StubLoginItem = StubLoginItem(),
    systemActions: StubSystemActions = StubSystemActions()
) -> (SettingsWindowController, () -> [NSWindow]) {
    let controller = SettingsWindowController(
        settings: settings, loginItem: loginItem, systemActions: systemActions)
    var shown: [NSWindow] = []
    controller.bringForward = { shown.append($0) }
    controller.shortcuts.postAccessibility = { _, _, _ in }
    controller.general.postAccessibility = { _, _, _ in }
    return (controller, { shown })
}

/// Cmd-, in the Settings window isn't the window's own key: it goes on to App ▸ Settings…, which
/// brings the same window forward again, and leaves it open.
@MainActor @Test func cmdCommaWithTheWindowKeyKeepsOneWindow() throws {
    let (controller, shown) = controller()
    controller.show()
    let window = try #require(controller.window)
    let settingsWindows = NSApp.windows.filter { $0 is SettingsWindow }.count
    var closes = 0
    let observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: window, queue: nil
    ) { _ in MainActor.assumeIsolated { closes += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }

    #expect(!window.performKeyEquivalent(with: try keyEvent(",", modifiers: .command)))
    controller.show()

    #expect(closes == 0)
    #expect(shown().count == 2)
    #expect(shown().allSatisfy { $0 === window })
    #expect(NSApp.windows.filter { $0 is SettingsWindow }.count == settingsWindows)
}

/// Closing the window while a recorder records ends the recording and removes its monitor.
@MainActor @Test func closingTheWindowEndsRecording() throws {
    let (controller, _) = controller()
    let window = try #require(controller.window)
    let field = ShortcutRecorderField()
    window.contentView?.addSubview(field)
    let installed = KeyMonitor.installed
    field.startRecording()
    #expect(KeyMonitor.installed == installed + 1)

    window.close()

    #expect(!field.isRecording)
    #expect(KeyMonitor.installed == installed)
}

/// A conflict or a refusal is read out by VoiceOver as it appears.
@MainActor @Test func aNoticeIsAnnounced() throws {
    let (controller, _) = controller()
    let model = controller.shortcuts
    var announced: [String] = []
    model.postAccessibility = { _, notification, userInfo in
        #expect(notification == .announcementRequested)
        announced.append(userInfo?[.announcement] as? String ?? "")
    }

    model.record(.chords([cmdP]), for: palette.id, at: .alternate)
    model.record(.chords([KeyChord("q", modifiers: .command)]), for: palette.id, at: .primary)
    model.record(
        .chords([KeyChord("j", modifiers: [.command, .option, .control])]), for: palette.id,
        at: .alternate)

    #expect(announced.count == 2)
    #expect(announced.first == "⌘P is used by \(goToItem.title).")
    #expect(announced.last?.contains("⌘Q") == true)
}

/// App ▸ Settings… a second time brings the same window forward, not a second one.
@MainActor @Test func showingTwiceBringsOneWindowForward() throws {
    let (controller, shown) = controller()

    controller.show()
    controller.show()

    let window = try #require(controller.window)
    #expect(shown().count == 2)
    #expect(shown().allSatisfy { $0 === window })
    #expect(window.toolbar?.selectedItemIdentifier?.rawValue == "general")
    #expect(window.title == "General")
    #expect(!window.isVisible)
}

/// The toolbar switches between General and Shortcuts, each at its own size, the window's top
/// edge staying put.
@MainActor @Test func theToolbarSwitchesPanes() throws {
    let (controller, _) = controller()
    controller.show()
    let window = try #require(controller.window)
    let toolbar = try #require(window.toolbar)
    #expect(toolbar.items.map(\.itemIdentifier.rawValue) == ["general", "shortcuts"])
    let general = window.contentViewController
    let top = window.frame.maxY

    func click(_ item: NSToolbarItem) throws {
        #expect(NSApp.sendAction(try #require(item.action), to: item.target, from: item))
    }

    try click(try #require(toolbar.items.last))

    #expect(toolbar.selectedItemIdentifier?.rawValue == "shortcuts")
    #expect(window.title == "Shortcuts")
    #expect(window.contentViewController !== general)
    #expect(window.contentRect(forFrameRect: window.frame).size == SettingsWindowController.size)
    #expect(window.frame.maxY == top)

    try click(try #require(toolbar.items.first))

    #expect(toolbar.selectedItemIdentifier?.rawValue == "general")
    #expect(window.contentViewController === general)
    #expect(
        window.contentRect(forFrameRect: window.frame).size
            == SettingsWindowController.generalSize)
    #expect(window.frame.maxY == top)
}

/// The Open at login checkbox reads the system's status each time the window shows and each
/// time the app becomes active, as the user may change it in System Settings meanwhile.
@MainActor @Test func showingOrActivatingReadsTheLoginItemAgain() {
    let loginItem = StubLoginItem(.notRegistered)
    let (controller, _) = controller(loginItem: loginItem)
    controller.show()
    #expect(!controller.general.opensAtLogin)

    loginItem.status = .enabled
    controller.show()
    #expect(controller.general.opensAtLogin)

    loginItem.status = .notRegistered
    NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
    #expect(!controller.general.opensAtLogin)
}

// MARK: Config file

private let textEdit = URL(fileURLWithPath: "/System/Applications/TextEdit.app")

/// The General pane names the config file, opens it in the default app for plain text, and
/// shows it in Finder.
@MainActor @Test func theGeneralPaneOpensAndRevealsTheConfigFile() async throws {
    let config = try await ConfigFixture("SettingsWindowControllerTests")
    let actions = StubSystemActions(defaultApplications: [.plainText: textEdit])
    let (controller, _) = controller(config.settings, systemActions: actions)
    let model = controller.general
    #expect(model.configFilePath == config.file.path)
    #expect(model.configFileIsDefault)

    model.openConfigFile()
    await settle { !actions.openedWithApp.isEmpty }
    model.revealConfigFile()
    if let task = model.reveal { _ = await bounded(task) }

    #expect(actions.openedWithApp == [OpenedWithApp(urls: [config.file], application: textEdit)])
    #expect(actions.revealed == [[config.file]])
}

/// Reveal in Finder with no file at the config file's place, as on a volume that isn't
/// connected, says so under the buttons rather than show Finder nothing.
@MainActor @Test func revealingAConfigFileThatIsntThereSaysSo() async throws {
    let config = try await ConfigFixture("SettingsWindowControllerTests")
    let actions = StubSystemActions()
    let (controller, _) = controller(config.settings, systemActions: actions)
    let model = controller.general
    var announced: [String] = []
    model.postAccessibility = { _, _, info in
        announced.append(info?[.announcement] as? String ?? "")
    }
    try FileManager.default.removeItem(at: config.file)

    model.revealConfigFile()
    if let task = model.reveal { _ = await bounded(task) }

    #expect(actions.revealed.isEmpty)
    #expect(model.configProblem == GeneralSettings.missingNote(config.file))
    #expect(announced == [GeneralSettings.missingNote(config.file)])
}

/// Change… moves the settings to the place chosen, a folder with no file in it here, which gets
/// them; Use Default moves them back, and is off at the default place.
@MainActor @Test func changeMovesTheConfigFileAndUseDefaultMovesItBack() async throws {
    let config = try await ConfigFixture("SettingsWindowControllerTests")
    let dropbox = config.folder.url.appending(path: "Dropbox")
    try FileManager.default.createDirectory(at: dropbox, withIntermediateDirectories: true)
    let (controller, _) = controller(config.settings)
    let model = controller.general
    model.chooseConfigLocation = { dropbox }
    config.settings.showHidden = true

    model.changeConfigLocation()
    if let task = model.move { _ = await bounded(task) }

    let moved = dropbox.appending(path: ConfigFile.name)
    #expect(model.configFilePath == moved.path)
    #expect(!model.configFileIsDefault)
    #expect(try String(contentsOf: moved, encoding: .utf8).contains(#""show-hidden" : true"#))
    #expect(config.settings.showHidden)

    model.useDefaultConfigLocation()
    if let task = model.move { _ = await bounded(task) }

    #expect(model.configFilePath == config.file.path)
    #expect(model.configFileIsDefault)
}

/// Cancelling the panel leaves the config file where it is.
@MainActor @Test func cancellingChangeLeavesTheConfigFile() async throws {
    let config = try await ConfigFixture("SettingsWindowControllerTests")
    let (controller, _) = controller(config.settings)
    let model = controller.general
    model.chooseConfigLocation = { nil }

    model.changeConfigLocation()
    if let task = model.move { _ = await bounded(task) }

    #expect(model.configFilePath == config.file.path)
}

/// Settings with no config file, as the tests' and the bench's, show no config section.
@MainActor @Test func withNoConfigFileTheGeneralPaneHasNoConfigSection() {
    let (controller, _) = controller()

    #expect(controller.general.configFilePath == nil)
}

/// Every registered command has one row, under its menu, with the registry's title and chords.
@MainActor @Test func theRowsComeFromTheRegistryGroupedAsTheMenus() throws {
    let (controller, _) = controller()
    let model = controller.shortcuts
    let bindings = PaneViewController.keyBindings(for: model.settings)

    let rows = model.sections.flatMap(\.rows)

    #expect(model.sections.map(\.title) == ["Searcher", "File", "Edit", "Go", "View", "Window"])
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

    // The symbols match as text, so ⌥⇧⌘P contains them too.
    model.search = "⇧⌘P"
    #expect(
        Set(model.sections.flatMap(\.rows).map(\.id))
            == [palette.id, ViewCommands.reverseSortDirection.id])

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

/// Reset and Reset All give rows their defaults, and the config file follows each change: the
/// shortcuts recorded are written to it, and Reset All leaves it with none.
@MainActor @Test func resetGivesARowItsDefaultsAndResetAllEveryRow() async throws {
    let config = try await ConfigFixture("SettingsWindowControllerTests")
    let (controller, _) = controller(config.settings)
    let model = controller.shortcuts
    let cmdJ = KeyChord("j", modifiers: [.command, .option, .control])
    let cmdL = KeyChord("l", modifiers: [.command, .option, .control])
    #expect(!model.canResetAll)
    func text() throws -> String { try String(contentsOf: config.file, encoding: .utf8) }

    model.record(.chords([cmdJ]), for: palette.id, at: .alternate)
    model.record(.chords([cmdL]), for: goToItem.id, at: .alternate)
    model.record(.removed, for: goToItem.id, at: .primary)
    func row(_ id: CommandID) throws -> ShortcutsSettings.Row {
        try #require(model.sections.flatMap(\.rows).first { $0.id == id })
    }
    #expect(try row(palette.id).isChanged)
    #expect(try row(goToItem.id).chords == KeyBindings.Chords(primary: nil, alternate: cmdL))
    #expect(model.canResetAll)
    await config.settings.flushConfigBounded()
    #expect(try text().contains(#""alternate" : "ctrl+opt+cmd+j""#))
    #expect(try text().contains(#""primary" : """#))

    model.reset(goToItem.id)
    #expect(try !row(goToItem.id).isChanged)
    #expect(try row(goToItem.id).chords.primary == goToItem.primary)
    #expect(try row(palette.id).chords.alternate == cmdJ)

    model.resetAll()
    #expect(model.settings.shortcuts.isEmpty)
    #expect(try row(palette.id).chords.alternate == palette.alternate)
    #expect(!model.canResetAll)
    await config.settings.flushConfigBounded()
    #expect(try text().contains(#""shortcuts" : {}"#))
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
