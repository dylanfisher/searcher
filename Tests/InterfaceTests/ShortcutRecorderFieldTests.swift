import AppKit
import Browser
import Testing

@testable import Interface

/// A recording field in an unshown window, and what it recorded.
@MainActor
private final class RecorderFixture {
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 300, height: 100), styleMask: [.titled],
        backing: .buffered, defer: true)
    let field = ShortcutRecorderField()
    var recorded: [ShortcutRecorderField.Recording] = []

    init() {
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(field)
        field.onRecord = { [weak self] in self?.recorded.append($0) }
    }

    /// A key event for the window, through the app as a real one comes.
    func key(
        _ type: NSEvent.EventType, _ ignoringModifiers: String, keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = [], isARepeat: Bool = false
    ) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: ignoringModifiers,
                charactersIgnoringModifiers: ignoringModifiers, isARepeat: isARepeat,
                keyCode: keyCode))
    }

    /// Releases the key a recording took, which ends the swallowing of its repeats, so no test
    /// leaves it for the next.
    func release(_ event: NSEvent) throws {
        NSApplication.shared.sendEvent(
            try key(.keyUp, event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode))
        #expect(!ShortcutRecorderField.isSwallowingHeldKey)
    }
}

@MainActor @Test func aKeyPressWhileRecordingIsSwallowedAndRecordsItsChords() throws {
    let fixture = RecorderFixture()
    let installed = KeyMonitor.installed

    fixture.field.startRecording()
    #expect(fixture.field.isRecording)
    #expect(KeyMonitor.installed == installed + 1)
    #expect(fixture.window.firstResponder === fixture.field)
    let event = try keyEvent("o", characters: "O", modifiers: [.command, .shift])

    #expect(fixture.field.handle(event) == nil)

    #expect(fixture.recorded == [.chords([KeyChord("o", modifiers: [.command, .shift])])])
    #expect(!fixture.field.isRecording)
    // What is left watches for the held key's release, until it comes.
    #expect(ShortcutRecorderField.isSwallowingHeldKey)
    // Once recording ends, keys pass.
    #expect(fixture.field.handle(event) === event)
    NSApplication.shared.sendEvent(
        try #require(
            NSEvent.keyEvent(
                with: .keyUp, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                windowNumber: 0, context: nil, characters: "O", charactersIgnoringModifiers: "o",
                isARepeat: false, keyCode: event.keyCode)))
    #expect(!ShortcutRecorderField.isSwallowingHeldKey)
}

@MainActor @Test func escCancelsAndDeleteRemoves() throws {
    let fixture = RecorderFixture()

    fixture.field.startRecording()
    let esc = try keyEvent("\u{1B}")
    #expect(fixture.field.handle(esc) == nil)
    #expect(fixture.recorded.isEmpty)
    #expect(!fixture.field.isRecording)
    try fixture.release(esc)

    fixture.field.startRecording()
    let delete = try keyEvent("\u{7F}")
    #expect(fixture.field.handle(delete) == nil)
    #expect(fixture.recorded == [.removed])
    #expect(!fixture.field.isRecording)
    try fixture.release(delete)

    // With a modifier, Esc and Delete are chords like any other.
    fixture.field.startRecording()
    let cmdDelete = try keyEvent("\u{7F}", modifiers: .command)
    _ = fixture.field.handle(cmdDelete)
    #expect(fixture.recorded.last == .chords([KeyChord(.delete, modifiers: .command)]))
    try fixture.release(cmdDelete)
}

/// Cmd-Q while recording is swallowed, so the app doesn't quit, and the settings refuse it.
@MainActor @Test func cmdQIsSwallowedAndRefused() throws {
    let fixture = RecorderFixture()
    let model = ShortcutsSettings(settings: untouchedSettings())
    let palette = WindowCommands.showPalette.id
    fixture.field.onRecord = { model.record($0, for: palette, at: .alternate) }

    fixture.field.startRecording()
    let cmdQ = try keyEvent("q", modifiers: .command)
    #expect(fixture.field.handle(cmdQ) == nil)

    #expect(model.settings.shortcuts.isEmpty)
    #expect(model.notices[palette]?.kind == .reserved)
    #expect(model.notices[palette]?.message.contains("⌘Q") == true)
    try fixture.release(cmdQ)
}

/// While the key a recording took is held, a fresh press of another key passes and ends the
/// swallowing. The held-key filter is called as its monitor calls it: the app's other local
/// monitors, such as another test's, come before or after it in no set order.
@MainActor @Test func aFreshPressEndsTheHeldKeysSwallowing() throws {
    let fixture = RecorderFixture()
    let p = try fixture.key(.keyDown, "p", keyCode: 35, modifiers: .command)
    let j = try fixture.key(.keyDown, "j", keyCode: 38)
    fixture.field.startRecording()
    #expect(fixture.field.handle(p) == nil)
    #expect(ShortcutRecorderField.isSwallowingHeldKey)

    #expect(ShortcutRecorderField.filterWhileHeld(j, holding: p.keyCode) === j)

    #expect(!ShortcutRecorderField.isSwallowingHeldKey)
}

/// While the key a recording took is held, another key's repeats and release pass, and the held
/// key's repeats are still swallowed until its release.
@MainActor @Test func anotherKeysRepeatAndReleasePassTheHeldKey() throws {
    let fixture = RecorderFixture()
    let p = try fixture.key(.keyDown, "p", keyCode: 35, modifiers: .command)
    let pRepeat = try fixture.key(.keyDown, "p", keyCode: 35, modifiers: .command, isARepeat: true)
    let jRepeat = try fixture.key(.keyDown, "j", keyCode: 38, isARepeat: true)
    let jUp = try fixture.key(.keyUp, "j", keyCode: 38)
    fixture.field.startRecording()
    #expect(fixture.field.handle(p) == nil)

    #expect(ShortcutRecorderField.filterWhileHeld(jRepeat, holding: p.keyCode) === jRepeat)
    #expect(ShortcutRecorderField.filterWhileHeld(jUp, holding: p.keyCode) === jUp)
    #expect(ShortcutRecorderField.filterWhileHeld(pRepeat, holding: p.keyCode) == nil)

    #expect(ShortcutRecorderField.isSwallowingHeldKey)
    try fixture.release(p)
}

/// No way out of recording leaves the monitor eating the app's keys.
@MainActor @Test func theMonitorGoesOnEveryExitPath() throws {
    let installed = KeyMonitor.installed
    let exits: [(String, @MainActor (RecorderFixture) -> Void)] = [
        ("the field resigns", { $0.window.makeFirstResponder(nil) }),
        (
            "the window resigns key",
            {
                NotificationCenter.default.post(
                    name: NSWindow.didResignKeyNotification, object: $0.window)
            }
        ),
        ("the field leaves its window", { $0.field.removeFromSuperview() }),
        ("the field is hidden", { $0.field.isHidden = true }),
        ("the field is turned off", { $0.field.isEnabled = false }),
    ]
    for (name, exit) in exits {
        let fixture = RecorderFixture()
        fixture.field.startRecording()
        #expect(KeyMonitor.installed == installed + 1, "\(name)")

        exit(fixture)

        #expect(!fixture.field.isRecording, "\(name)")
        #expect(KeyMonitor.installed == installed, "\(name)")
    }

    // Released while recording. AppKit autoreleases the view, so the pool drains first.
    weak var released: ShortcutRecorderField?
    autoreleasepool {
        let field = ShortcutRecorderField()
        released = field
        field.startRecording()
        #expect(KeyMonitor.installed == installed + 1)
    }
    #expect(released == nil)
    #expect(KeyMonitor.installed == installed)
}

@MainActor @Test func theFieldShowsItsStatesAndTellsVoiceOver() throws {
    let fixture = RecorderFixture()
    let field = fixture.field
    field.label = "Copy, alternate shortcut"

    #expect(field.text == ShortcutRecorderField.emptyPrompt)
    #expect(field.accessibilityValue() as? String == "None")
    #expect(field.accessibilityLabel() == "Copy, alternate shortcut")
    #expect(field.accessibilityRole() == .button)

    field.chord = KeyChord("c", modifiers: [.control, .command])
    #expect(field.text == "⌃⌘C")
    #expect(field.accessibilityValue() as? String == "⌃⌘C")

    #expect(field.accessibilityPerformPress())
    #expect(field.text == ShortcutRecorderField.recordingPrompt)
    #expect(field.accessibilityValue() as? String == "Recording")
    field.stopRecording()

    field.mouseEntered(with: try keyEvent("a"))
    #expect(field.fill == HoverButton.hoverFill)
    field.isEnabled = false
    #expect(field.fill == nil)
    #expect(!field.acceptsFirstResponder)
    field.startRecording()
    #expect(!field.isRecording)
}

/// Counts the runs of a menu item's action.
@MainActor
private final class ActionCounter: NSObject {
    var runs = 0
    @objc func run(_ sender: Any?) { runs += 1 }
}

/// Recording a chord never runs a command, through the real path a key press takes: the app's
/// `sendEvent`, which hands the press to the local monitors and then to the menus' key
/// equivalents. The recording gives a menu item the chord at once, as the settings do
/// (`MainMenuBuilder.showChords`), and the key is held: neither the press, its repeats nor its
/// release runs the item. The next press of the chord does. The repeats of a held Return, which
/// started recording, record nothing.
@MainActor @Test func recordingAChordThroughTheAppNeverRunsItsCommand() throws {
    let app = NSApplication.shared
    let counter = ActionCounter()
    let item = NSMenuItem(
        title: "Command", action: #selector(ActionCounter.run(_:)), keyEquivalent: "")
    item.target = counter
    let menu = NSMenu(title: "Menu")
    menu.addItem(item)
    let menuItem = NSMenuItem(title: "Menu", action: nil, keyEquivalent: "")
    menuItem.submenu = menu
    let bar = NSMenu()
    bar.addItem(menuItem)
    let mainMenu = app.mainMenu
    app.mainMenu = bar
    defer { app.mainMenu = mainMenu }

    let fixture = RecorderFixture()
    fixture.field.onRecord = { recording in
        fixture.recorded.append(recording)
        guard case .chords(let candidates) = recording, let chord = candidates.last else { return }
        item.keyEquivalent = chord.keyEquivalent
        item.keyEquivalentModifierMask = chord.keyEquivalentModifierMask
    }
    func key(_ type: NSEvent.EventType, isARepeat: Bool = false) throws -> NSEvent {
        try #require(
            NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [.command, .option], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, characters: "π",
                charactersIgnoringModifiers: "p", isARepeat: isARepeat, keyCode: 35))
    }
    fixture.field.startRecording()
    let heldReturn = try #require(
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: true, keyCode: 36))
    app.sendEvent(heldReturn)
    #expect(fixture.recorded.isEmpty)
    #expect(fixture.field.isRecording)
    app.sendEvent(try key(.keyDown))
    app.sendEvent(try key(.keyDown, isARepeat: true))
    app.sendEvent(try key(.keyDown, isARepeat: true))
    app.sendEvent(try key(.keyUp))

    #expect(fixture.recorded == [.chords([KeyChord("p", modifiers: [.command, .option])])])
    #expect(counter.runs == 0)
    #expect(!fixture.field.isRecording)
    #expect(!ShortcutRecorderField.isSwallowingHeldKey)

    // Recording is over: the next press is the command's.
    app.sendEvent(try key(.keyDown))
    #expect(counter.runs == 1)
}
