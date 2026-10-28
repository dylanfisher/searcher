import AppKit

/// The dots after a tagged item's name in a list or a column, one per color of its tags, as
/// Finder draws them: 10-point circles in each tag's color, overlapping by half when there are
/// several, the first tag's on top, at most three. On an emphasized selection each has a white
/// outline, as Finder's does; elsewhere a thin rim of the tag's color, the fill being a lighter
/// shade of it. The row's VoiceOver label names the colors, so the dots aren't an element of
/// their own (docs/decisions/0124-tags-in-rows-and-preview.md,
/// docs/decisions/0127-tag-colors-and-pill-widths.md).
@MainActor
final class RowTagDotsView: NSView {
    /// A dot's diameter, and how far each dot after the first starts from the one before.
    static let diameter: CGFloat = 10
    static let step: CGFloat = 5
    /// The most dots a row shows.
    static let shownCount = 3
    /// The outline's width, which the view leaves room for around the dots.
    static let outline: CGFloat = 1

    /// The width and height of the view showing `count` colors.
    static func size(count: Int) -> NSSize {
        let shown = CGFloat(min(count, shownCount))
        return NSSize(
            width: diameter + (shown - 1) * step + 2 * outline, height: diameter + 2 * outline)
    }

    /// The color labels shown, in the item's order.
    private(set) var labels: [Int] = []

    var isOnEmphasizedSelection = false {
        didSet {
            if isOnEmphasizedSelection != oldValue { needsDisplay = true }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("RowTagDotsView is built in code")
    }

    /// Shows the first `shownCount` of `labels` and sizes the view to them.
    func show(_ labels: some Sequence<Int>) {
        let shown = Array(labels.prefix(Self.shownCount))
        guard shown != self.labels else { return }
        self.labels = shown
        setFrameSize(Self.size(count: shown.count))
        needsDisplay = true
    }

    /// The circle of the dot at `index`, in the view's coordinates.
    func dotRect(at index: Int) -> NSRect {
        NSRect(
            x: Self.outline + CGFloat(index) * Self.step,
            y: (bounds.height - Self.diameter) / 2, width: Self.diameter, height: Self.diameter)
    }

    override func draw(_ dirtyRect: NSRect) {
        // The first tag's dot is drawn last, so it is on top.
        for (index, label) in labels.enumerated().reversed() {
            let circle = NSBezierPath(ovalIn: dotRect(at: index))
            NSColor.tagLabelDot(label).setFill()
            circle.fill()
            if isOnEmphasizedSelection {
                NSColor.white.setStroke()
                circle.lineWidth = Self.outline
            } else {
                NSColor.tagLabel(label).setStroke()
                circle.lineWidth = Self.outline / 2
            }
            circle.stroke()
        }
    }
}
