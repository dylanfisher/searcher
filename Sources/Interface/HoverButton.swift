import AppKit

/// A borderless image button that shows every state a control has: a rounded fill under the
/// mouse, the path bar's hover color; a darker fill while pressed; the focus ring around that
/// rounded shape; and no fill, with AppKit's dimmed image, while disabled
/// (docs/decisions/0110-interaction-states.md).
@MainActor
final class HoverButton: NSButton {
    /// The fill under the mouse.
    static let hoverFill = NSColor.quaternaryLabelColor
    /// The fill while the button is pressed.
    static let pressedFill = NSColor.tertiaryLabelColor
    /// The width and height, so the fill has room around a symbol.
    static let side: CGFloat = 22
    private static let cornerRadius: CGFloat = 4

    /// Whether the mouse is over the button.
    private(set) var isHovered = false {
        didSet {
            if isHovered != oldValue { needsDisplay = true }
        }
    }

    init() {
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
        guard isEnabled else { return nil }
        if isHighlighted { return Self.pressedFill }
        return isHovered ? Self.hoverFill : nil
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    override var isHidden: Bool {
        // A hidden button gets no mouseExited, so it would show the hover when shown again.
        didSet { if isHidden { isHovered = false } }
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
