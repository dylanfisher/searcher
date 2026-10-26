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
/// is taken, the field loses the keys, its window loses the keys or closes, it leaves its window,
/// it is turned off, or it is released, so no exit leaves a monitor eating the app's keys.
/// After a key is taken, a second monitor swallows that key's repeats and its release, which
/// would otherwise reach the menus, where the chord may now run a command.
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
    /// Swallows the repeats and the release of the key just taken, while it is held. It belongs
    /// to no field, so the key stays swallowed if the settings change takes the field away or
    /// the keys from it.
    private static var heldKey: KeyMonitor?
    /// Whether the key just taken is still held, its repeats and release swallowed.
    static var isSwallowingHeldKey: Bool { heldKey != nil }
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
    /// Observers of the window losing the keys and closing, while recording.
    private var windowObservers: [NSObjectProtocol] = []

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

    // The monitor removes itself as it goes; the observers of the window are removed here.
    isolated deinit {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
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
        // Not `self?.handle(event) ?? event`: that passes on the nil that swallows a press.
        monitor = KeyMonitor { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        if let window {
            // A window closed without having the keys, as in code, never resigns key.
            windowObservers = [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification]
                .map { name in
                    NotificationCenter.default.addObserver(
                        forName: name, object: window, queue: nil
                    ) { [weak self] _ in
                        MainActor.assumeIsolated { self?.stopRecording() }
                    }
                }
        }
        needsDisplay = true
        updateAccessibilityValue()
    }

    /// Stops recording, and removes the monitor, without recording anything.
    func stopRecording() {
        guard isRecording else { return }
        monitor = nil
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers = []
        needsDisplay = true
        updateAccessibilityValue()
    }

    /// Takes a key press while recording: nil swallows it, so no menu or view sees it. A repeat,
    /// such as of the Return that started recording, is swallowed and not recorded.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard isRecording, event.type == .keyDown else { return event }
        if event.isARepeat { return nil }
        let candidates = KeyChord.candidates(for: event)
        // A key `KeyChord` can't spell, such as forward delete, is not a shortcut; recording
        // goes on.
        guard let first = candidates.first else { return nil }
        let isPlain = first.modifiers.isEmpty
        stopRecording()
        Self.swallowRepeatsAndRelease(of: event.keyCode)
        if isPlain, first.key == .escape { return nil }
        onRecord(isPlain && first.key == .delete ? .removed : .chords(candidates))
        return nil
    }

    /// Swallows the repeats of the key with `keyCode` and its release, until the release or the
    /// next fresh press of any key, which passes.
    private static func swallowRepeatsAndRelease(of keyCode: UInt16) {
        heldKey = KeyMonitor(matching: [.keyDown, .keyUp]) {
            filterWhileHeld($0, holding: keyCode)
        }
    }

    /// The held-key monitor's handler, while the key with `keyCode` is held: nil swallows a
    /// repeat or the release of that key. A fresh press of any key passes and ends the
    /// swallowing, as the release does; another key's repeats and release pass.
    static func filterWhileHeld(_ event: NSEvent, holding keyCode: UInt16) -> NSEvent? {
        guard event.type == .keyUp || event.isARepeat else {
            heldKey = nil
            return event
        }
        guard event.keyCode == keyCode else { return event }
        if event.type == .keyUp { heldKey = nil }
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

/// A local key monitor, removed when released, so a field released while recording leaves none
/// behind.
@MainActor
final class KeyMonitor {
    /// How many are installed, for the tests to see none is left behind.
    private(set) static var installed = 0
    private let token: Any

    init(
        matching mask: NSEvent.EventTypeMask = .keyDown,
        _ handler: @escaping @MainActor (NSEvent) -> NSEvent?
    ) {
        guard let token = NSEvent.addLocalMonitorForEvents(matching: mask, handler: handler)
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
