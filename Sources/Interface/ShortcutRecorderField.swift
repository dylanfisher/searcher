import AppKit
import Browser
import SwiftUI

/// A field that shows one slot's chord and records the next key press as its new chord. A click,
/// or Space or Return while it has the keys, starts recording; while it records, a local event
/// monitor takes every key press before the menus and the views see it. Esc cancels, plain
/// Delete removes the chord, and any other key is recorded. The field holds no rules: what it
/// records goes to `onRecord`, which asks `KeyBindings`
/// (docs/decisions/0106-primary-and-alternate-shortcuts.md).
///
/// It draws hover, pressed, focused, recording and disabled
/// (docs/decisions/0110-interaction-states.md). Recording ends, and the monitor goes, when a key
/// is taken, the field loses the keys, its window loses the keys, it leaves its window, it is
/// turned off, or it is released, so no exit leaves a monitor eating the app's keys.
@MainActor
final class ShortcutRecorderField: NSView {
    /// What a recording gave.
    enum Recording: Equatable {
        /// The chords the key press can mean (`KeyChord.candidates(for:)`).
        case chords([KeyChord])
        /// Delete: the slot is to have no chord.
        case removed
    }

    /// The chord the slot has; nil for none.
    var chord: KeyChord? {
        didSet {
            guard chord != oldValue else { return }
            needsDisplay = true
            updateAccessibilityValue()
        }
    }

    /// What VoiceOver reads before the chord, such as "Copy, alternate shortcut".
    var label = "" {
        didSet { setAccessibilityLabel(label) }
    }

    var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { stopRecording() }
            setAccessibilityEnabled(isEnabled)
            needsDisplay = true
        }
    }

    /// Runs with each key press recorded; not for Esc.
    var onRecord: @MainActor (Recording) -> Void = { _ in }

    /// Whether the next key press is recorded: only while the field has a key monitor.
    var isRecording: Bool { monitor != nil }

    private var monitor: KeyMonitor?
    private var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }
    private var isPressed = false {
        didSet {
            if isPressed != oldValue { needsDisplay = true }
        }
    }
    private var resignKeyObserver: NSObjectProtocol?

    static let height: CGFloat = 22
    private static let cornerRadius: CGFloat = 5
    /// What the field shows while it records.
    static let recordingPrompt = "Type Shortcut"
    /// What the field shows for a slot with no chord.
    static let emptyPrompt = "Click to Record"

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.height))
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityHelp(
            "Click, then press the keys. Esc cancels; Delete removes the shortcut.")
        updateAccessibilityValue()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ShortcutRecorderField is built in code")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.height)
    }

    // MARK: Recording

    /// Starts recording the next key press, with the keys in the field.
    func startRecording() {
        guard isEnabled, !isRecording else { return }
        if let window, window.firstResponder !== self {
            guard window.makeFirstResponder(self) else { return }
        }
        monitor = KeyMonitor { [weak self] event in self?.handle(event) ?? event }
        if let window {
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopRecording() }
            }
        }
        needsDisplay = true
        updateAccessibilityValue()
    }

    /// Stops recording, and removes the monitor, without recording anything.
    func stopRecording() {
        guard isRecording else { return }
        monitor = nil
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
        }
        resignKeyObserver = nil
        needsDisplay = true
        updateAccessibilityValue()
    }

    /// Takes a key press while recording: nil swallows it, so no menu or view sees it.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording, event.type == .keyDown else { return event }
        let candidates = KeyChord.candidates(for: event)
        // A key `KeyChord` can't spell, such as forward delete, is not a shortcut; recording
        // goes on.
        guard let first = candidates.first else { return nil }
        let isPlain = first.modifiers.isEmpty
        stopRecording()
        if isPlain, first.key == .escape { return nil }
        onRecord(isPlain && first.key == .delete ? .removed : .chords(candidates))
        return nil
    }

    // MARK: Ending on every exit

    override func resignFirstResponder() -> Bool {
        stopRecording()
        return super.resignFirstResponder()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func viewDidHide() {
        super.viewDidHide()
        stopRecording()
        isHovered = false
    }

    // MARK: Mouse and keys

    override var acceptsFirstResponder: Bool { isEnabled }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { startRecording() }
    }

    /// Space or Return starts recording, as either presses a button.
    override func keyDown(with event: NSEvent) {
        guard isEnabled, let chord = KeyChord(event: event), chord.modifiers.isEmpty,
            chord.key == .space || chord.key == .return
        else {
            super.keyDown(with: event)
            return
        }
        startRecording()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        startRecording()
        return true
    }

    // MARK: Drawing

    /// The fill drawn over the field's background now, if any.
    var fill: NSColor? {
        guard isEnabled else { return nil }
        if isPressed { return HoverButton.pressedFill }
        return isHovered ? HoverButton.hoverFill : nil
    }

    /// What the field shows now.
    var text: String {
        if isRecording { return Self.recordingPrompt }
        return chord?.symbols ?? Self.emptyPrompt
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = self.shape(in: bounds.insetBy(dx: 1, dy: 1))
        NSColor.controlBackgroundColor.setFill()
        shape.fill()
        if let fill {
            fill.setFill()
            shape.fill()
        }
        if isRecording {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            shape.lineWidth = 2
        } else {
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1
        }
        shape.stroke()

        let color: NSColor =
            if !isEnabled {
                .tertiaryLabelColor
            } else if isRecording || chord == nil {
                .secondaryLabelColor
            } else {
                .labelColor
            }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: color, .paragraphStyle: paragraph,
            ])
        let size = string.size()
        string.draw(
            in: NSRect(
                x: bounds.minX + 4, y: bounds.midY - size.height / 2, width: bounds.width - 8,
                height: size.height))
    }

    override var focusRingMaskBounds: NSRect { bounds }

    // The recording ring stands in for the focus ring while recording.
    override func drawFocusRingMask() {
        guard !isRecording else { return }
        shape(in: bounds).fill()
    }

    private func shape(in rect: NSRect) -> NSBezierPath {
        NSBezierPath(roundedRect: rect, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
    }

    private func updateAccessibilityValue() {
        setAccessibilityValue(isRecording ? "Recording" : chord?.symbols ?? "None")
    }
}

/// A local key-down monitor, removed when released, so a field released while recording leaves
/// none behind.
@MainActor
final class KeyMonitor {
    /// How many are installed, for the tests to see none is left behind.
    private(set) static var installed = 0
    private let token: Any

    init(_ handler: @escaping @MainActor (NSEvent) -> NSEvent?) {
        guard let token = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: handler)
        else {
            preconditionFailure("AppKit refused a local key monitor")
        }
        self.token = token
        Self.installed += 1
    }

    isolated deinit {
        NSEvent.removeMonitor(token)
        Self.installed -= 1
    }
}

/// `ShortcutRecorderField` in a SwiftUI view.
struct ShortcutRecorder: NSViewRepresentable {
    let chord: KeyChord?
    let label: String
    var isEnabled = true
    let onRecord: @MainActor (ShortcutRecorderField.Recording) -> Void

    func makeNSView(context: Context) -> ShortcutRecorderField {
        ShortcutRecorderField()
    }

    func updateNSView(_ field: ShortcutRecorderField, context: Context) {
        field.chord = chord
        field.label = label
        field.isEnabled = isEnabled
        field.onRecord = onRecord
    }
}
