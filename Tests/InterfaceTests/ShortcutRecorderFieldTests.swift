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
    #expect(KeyMonitor.installed == installed)
    // Once recording ends, keys pass.
    #expect(fixture.field.handle(event) === event)
}

@MainActor @Test func escCancelsAndDeleteRemoves() throws {
    let fixture = RecorderFixture()

    fixture.field.startRecording()
    #expect(fixture.field.handle(try keyEvent("\u{1B}")) == nil)
    #expect(fixture.recorded.isEmpty)
    #expect(!fixture.field.isRecording)

    fixture.field.startRecording()
    #expect(fixture.field.handle(try keyEvent("\u{7F}")) == nil)
    #expect(fixture.recorded == [.removed])
    #expect(!fixture.field.isRecording)

    // With a modifier, Esc and Delete are chords like any other.
    fixture.field.startRecording()
    _ = fixture.field.handle(try keyEvent("\u{7F}", modifiers: .command))
    #expect(fixture.recorded.last == .chords([KeyChord(.delete, modifiers: .command)]))
}

/// Cmd-Q while recording is swallowed, so the app doesn't quit, and the settings refuse it.
@MainActor @Test func cmdQIsSwallowedAndRefused() throws {
    let fixture = RecorderFixture()
    let model = ShortcutsSettings(settings: untouchedSettings())
    let palette = WindowCommands.showPalette.id
    fixture.field.onRecord = { model.record($0, for: palette, at: .alternate) }

    fixture.field.startRecording()
    #expect(fixture.field.handle(try keyEvent("q", modifiers: .command)) == nil)

    #expect(model.settings.shortcuts.isEmpty)
    #expect(model.notices[palette]?.kind == .reserved)
    #expect(model.notices[palette]?.message.contains("⌘Q") == true)
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
