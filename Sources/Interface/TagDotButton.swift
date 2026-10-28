import AppKit
import Browser

/// One of the row menu's tag dots: a circle in its Finder tag's color, which adds the tag to
/// the selection or takes it off, as Finder's menu dots do. A white check shows that every
/// selected item has the tag and a white dash that some do. Under the mouse the dot grows and
/// shows what a click does, + to add and × to remove; pressed, it darkens; disabled, it fades;
/// with the keys it takes a round focus ring (docs/decisions/0110-interaction-states.md,
/// docs/decisions/0121-tag-commands.md).
@MainActor
final class TagDotButton: NSButton {
    /// The width and height of the button, which leaves room for the dot to grow.
    static let side: CGFloat = 20
    /// The dot's diameter at rest, and under the mouse or pressed.
    static let restDiameter: CGFloat = 12
    static let hoverDiameter: CGFloat = 16
    /// How much a press darkens the dot, and how faint a disabled one is.
    static let pressedShade: CGFloat = 0.25
    static let disabledAlpha: CGFloat = 0.35

    /// How far outside the grown dot a press still takes it.
    static let hitMargin: CGFloat = 2

    /// Whether `point`, in a button whose bounds are `bounds`, is on the dot: inside the circle
    /// it grows to under the mouse, or within `hitMargin` of it. The button's corners aren't.
    static func isOnDot(_ point: NSPoint, in bounds: NSRect) -> Bool {
        let radius = hoverDiameter / 2 + hitMargin
        return hypot(point.x - bounds.midX, point.y - bounds.midY) <= radius
    }

    /// A cell that takes a press on the dot (`isOnDot`) and nowhere else. AppKit's own may take
    /// none on a button with no title, image or bezel, so a click would pass the dot by.
    private final class Cell: NSButtonCell {
        override func hitTest(for event: NSEvent, in cellFrame: NSRect, of controlView: NSView)
            -> NSCell.HitResult
        {
            let point = controlView.convert(event.locationInWindow, from: nil)
            return TagDotButton.isOnDot(point, in: cellFrame) ? [.contentArea, .trackableArea] : []
        }
    }

    // A press in a corner, off the dot, goes to the view behind it, the dots' row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard Self.isOnDot(convert(point, from: superview), in: bounds) else { return nil }
        return super.hitTest(point)
    }

    override class var cellClass: AnyClass? {
        get { Cell.self }
        set {}
    }

    let finderTag: FinderTag
    /// Runs when the mouse enters or leaves the button.
    var onHover: @MainActor (TagDotButton) -> Void = { _ in }

    /// How many of the selected items have the tag; nil until their tags are read.
    var coverage: FinderTag.Coverage? {
        didSet {
            needsDisplay = true
            setAccessibilityLabel(actionTitle)
        }
    }

    private(set) var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            onHover(self)
        }
    }

    init(_ tag: FinderTag) {
        finderTag = tag
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        bezelStyle = .accessoryBarAction
        isBordered = false
        imagePosition = .imageOnly
        // Menus track the mouse while the app isn't active, so the area is always on.
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self))
        // With no title and no bezel, AppKit doesn't report it as a button by itself.
        setAccessibilityRole(.button)
        setAccessibilityLabel(actionTitle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TagDotButton is built in code")
    }

    /// What a click does, as Finder's Edit menu names it once done: "Remove Tag “Red”" when
    /// every selected item has the tag, otherwise "Add Tag “Red”"; the tag's name alone until
    /// the items' tags are read.
    var actionTitle: String {
        switch coverage {
        case .allItems: "Remove Tag “\(finderTag.name)”"
        case .someItems, .noItems: "Add Tag “\(finderTag.name)”"
        case nil: finderTag.name
        }
    }

    /// The tag's color, as Finder draws it.
    var color: NSColor { .tagLabel(finderTag.label) }

    /// The mark drawn on the dot now.
    enum Mark: Equatable {
        case plus, cross, check, dash
    }

    var mark: Mark? {
        if isHovered, isEnabled {
            return coverage == .allItems ? .cross : coverage == nil ? nil : .plus
        }
        return switch coverage {
        case .allItems: .check
        case .someItems: .dash
        case .noItems, nil: nil
        }
    }

    /// The fill drawn now: the tag's color, darkened while pressed and faint while disabled.
    var fill: NSColor {
        if !isEnabled { return color.withAlphaComponent(Self.disabledAlpha) }
        if isHighlighted {
            return color.blended(withFraction: Self.pressedShade, of: .black) ?? color
        }
        return color
    }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

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
        let grows = (isHovered || isHighlighted) && isEnabled
        let diameter = grows ? Self.hoverDiameter : Self.restDiameter
        let dot = NSRect(
            x: bounds.midX - diameter / 2, y: bounds.midY - diameter / 2, width: diameter,
            height: diameter)
        let circle = NSBezierPath(ovalIn: dot)
        fill.setFill()
        circle.fill()
        (color.shadow(withLevel: 0.2) ?? color).withAlphaComponent(
            isEnabled ? 1 : Self.disabledAlpha
        )
        .setStroke()
        circle.lineWidth = 1
        circle.stroke()
        guard let mark else { return }
        let inset = dot.insetBy(dx: diameter * 0.3, dy: diameter * 0.3)
        let path = NSBezierPath()
        switch mark {
        case .plus:
            path.move(to: NSPoint(x: inset.minX, y: inset.midY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.midY))
            path.move(to: NSPoint(x: inset.midX, y: inset.minY))
            path.line(to: NSPoint(x: inset.midX, y: inset.maxY))
        case .cross:
            path.move(to: NSPoint(x: inset.minX, y: inset.minY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            path.move(to: NSPoint(x: inset.minX, y: inset.maxY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.minY))
        case .check:
            let points = checkPoints(in: inset)
            path.move(to: points[0])
            for point in points.dropFirst() { path.line(to: point) }
        case .dash:
            path.move(to: NSPoint(x: inset.minX, y: inset.midY))
            path.line(to: NSPoint(x: inset.maxX, y: inset.midY))
        }
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        NSColor.white.withAlphaComponent(isEnabled ? 1 : Self.disabledAlpha).setStroke()
        path.stroke()
    }

    /// The check's three points in `rect`: from the middle of its left edge down to its point,
    /// then up to its top right. A button is flipped, so down is toward a larger y.
    func checkPoints(in rect: NSRect) -> [NSPoint] {
        let bottom = isFlipped ? rect.maxY : rect.minY
        let top = isFlipped ? rect.minY : rect.maxY
        return [
            NSPoint(x: rect.minX, y: rect.midY),
            NSPoint(x: rect.minX + rect.width * 0.4, y: bottom),
            NSPoint(x: rect.maxX, y: top),
        ]
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)).fill()
    }

    /// A dot in `tag`'s color for its main menu item, which has no room for the marks.
    static func image(for tag: FinderTag) -> NSImage {
        let side = restDiameter
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let color = NSColor.tagLabel(tag.label)
            let circle = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            color.setFill()
            circle.fill()
            (color.shadow(withLevel: 0.2) ?? color).setStroke()
            circle.stroke()
            return true
        }
        image.accessibilityDescription = tag.name
        return image
    }
}
