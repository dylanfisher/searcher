import AppKit

/// A borderless image button that shows every state a control has. The `.fill` look draws a
/// rounded fill under the mouse, the path bar's hover color, a darker fill while pressed, and no
/// fill, with AppKit's dimmed image, while disabled. The `.glyph` look, Finder's sidebar eject
/// button's, draws no fill: the image is light at rest, darker under the mouse, darker still
/// while pressed and faint while disabled. Both draw the focus ring around the rounded shape
/// (docs/decisions/0110-interaction-states.md).
@MainActor
final class HoverButton: NSButton {
    /// How the button shows hover and press.
    enum Look {
        case fill
        case glyph
    }

    /// A `.glyph` button's state, which picks its image's tint.
    enum GlyphState {
        case rest
        case hovered
        case pressed
        case disabled
    }

    /// The fill under the mouse.
    static let hoverFill = NSColor.quaternaryLabelColor
    /// The fill while the button is pressed.
    static let pressedFill = NSColor.tertiaryLabelColor
    /// The width and height, so the fill has room around a symbol.
    static let side: CGFloat = 22
    private static let cornerRadius: CGFloat = 4
    /// A `.glyph` button's tints on an emphasized selection, the selected row's text color at
    /// the label colors' levels, since the label colors would vanish on the accent.
    private static let emphasizedGlyphTints: [GlyphState: NSColor] = [
        .rest: .alternateSelectedControlTextColor.withAlphaComponent(0.6),
        .hovered: .alternateSelectedControlTextColor.withAlphaComponent(0.8),
        .pressed: .alternateSelectedControlTextColor,
        .disabled: .alternateSelectedControlTextColor.withAlphaComponent(0.35),
    ]

    let look: Look

    /// Whether the mouse is over the button.
    private(set) var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    /// Whether the button sits on an emphasized selection, as on a selected row while its list
    /// has the keys of the key window. Only the `.glyph` look changes for it.
    var isOnEmphasizedSelection = false {
        didSet {
            if isOnEmphasizedSelection != oldValue { needsDisplay = true }
        }
    }

    init(look: Look = .fill) {
        self.look = look
        super.init(frame: .zero)
        bezelStyle = .accessoryBarAction
        isBordered = false
        imagePosition = .imageOnly
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self))
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("HoverButton is built in code")
    }

    /// The fill drawn under the image now, if any.
    var fill: NSColor? {
        guard look == .fill, isEnabled else { return nil }
        if isHighlighted { return Self.pressedFill }
        return isHovered ? Self.hoverFill : nil
    }

    var glyphState: GlyphState {
        if !isEnabled { return .disabled }
        if isHighlighted { return .pressed }
        return isHovered ? .hovered : .rest
    }

    /// The tint a `.glyph` button's image has now.
    var glyphTint: NSColor {
        Self.glyphTint(glyphState, onEmphasizedSelection: isOnEmphasizedSelection)
    }

    /// A `.glyph` button's tint in `state`: the label colors, from tertiary at rest to the
    /// label color pressed, quaternary while disabled.
    static func glyphTint(_ state: GlyphState, onEmphasizedSelection: Bool) -> NSColor {
        if onEmphasizedSelection, let tint = emphasizedGlyphTints[state] { return tint }
        return switch state {
        case .rest: .tertiaryLabelColor
        case .hovered: .secondaryLabelColor
        case .pressed: .labelColor
        case .disabled: .quaternaryLabelColor
        }
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    // A button hidden, with or without its ancestors, or taken out of its window gets no
    // mouseExited, so it would show the hover when shown again.
    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        isHovered = false
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        if let fill {
            fill.setFill()
            shape.fill()
        }
        // The tint is set as the button draws: a press highlights the button's cell, not the
        // button, so no setter of the button runs when the press starts or ends.
        if look == .glyph, contentTintColor != glyphTint {
            contentTintColor = glyphTint
        }
        super.draw(dirtyRect)
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        shape.fill()
    }

    private var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
    }
}
