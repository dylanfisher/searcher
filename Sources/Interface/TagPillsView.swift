import AppKit
import Base

/// The column preview's tags, as Finder's preview shows them: each tag's name in a rounded pill
/// filled with its color, in the label color, the pills in a row that wraps at the preview's
/// width. A tag without a color gets a light gray pill. VoiceOver reads each pill's name
/// (docs/decisions/0124-tags-in-rows-and-preview.md).
@MainActor
final class TagPillsView: NSView {
    /// The space between pills, across and down.
    static let spacing: CGFloat = 4

    /// The pills, in the tags' order.
    private(set) var pills: [TagPillView] = []

    /// The width the pills wrap at.
    var wrapWidth: CGFloat = 0 {
        didSet {
            guard wrapWidth != oldValue else { return }
            invalidateIntrinsicContentSize()
            needsLayout = true
        }
    }

    override var isFlipped: Bool { true }

    /// The tags' names, in order.
    var names: [String] { pills.map(\.label.stringValue) }

    /// The pills' labels, which VoiceOver reads.
    var labels: [NSTextField] { pills.map(\.label) }

    /// Shows `entries`, the tags as `FinderTags` reads them, "Red\n6".
    func show(_ entries: [String]) {
        for pill in pills { pill.removeFromSuperview() }
        pills = entries.map {
            TagPillView(name: FinderTags.name(of: $0), label: FinderTags.label(of: $0))
        }
        for pill in pills { addSubview(pill) }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var intrinsicContentSize: NSSize {
        let frames = Self.frames(of: pills.map(\.fittingSize), width: wrapWidth)
        return NSSize(width: NSView.noIntrinsicMetric, height: frames.last?.maxY ?? 0)
    }

    override func layout() {
        super.layout()
        let frames = Self.frames(of: pills.map(\.fittingSize), width: bounds.width)
        for (pill, frame) in zip(pills, frames) where pill.frame != frame {
            pill.frame = frame
        }
    }

    /// The frames of pills of `sizes`, laid in rows from the top left, wrapping before a pill
    /// that would end past `width`. A pill wider than `width` takes a row and is narrowed to it.
    static func frames(of sizes: [NSSize], width: CGFloat) -> [NSRect] {
        var frames: [NSRect] = []
        var origin = NSPoint.zero
        var rowHeight: CGFloat = 0
        for size in sizes {
            if origin.x > 0, origin.x + size.width > width {
                origin = NSPoint(x: 0, y: origin.y + rowHeight + spacing)
                rowHeight = 0
            }
            let pillWidth = width > 0 ? min(size.width, width) : size.width
            frames.append(
                NSRect(origin: origin, size: NSSize(width: pillWidth, height: size.height)))
            origin.x += pillWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}

/// One tag's pill: its name in the label color on its color, or on light gray for a tag without
/// one.
@MainActor
final class TagPillView: NSView {
    /// The space between the label and the pill's edge, across and down. The label's cell keeps
    /// 2 points either side of the name, so the name is 4 from the edge, as in Finder's pills
    /// (docs/decisions/0127-tag-colors-and-pill-widths.md).
    static let padding = NSSize(width: 2, height: 0)
    static let cornerRadius: CGFloat = 4
    /// How strong the tag's color is under the name: Finder's yellow and orange pills measure as
    /// their system color at 63% over white. It keeps the name readable on the darker colors,
    /// and dark mode darkens the fill under white text.
    static let fillAlpha: CGFloat = 0.63

    let label: NSTextField
    /// The tag's color label, 0 for none.
    let colorLabel: Int

    init(name: String, label colorLabel: Int) {
        label = NSTextField(labelWithString: name)
        self.colorLabel = colorLabel
        super.init(frame: .zero)
        label.font = ColumnPreviewView.detailFont
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("TagPillView is built in code")
    }

    /// What the pill is filled with: its tag's color, or a light gray for a tag without one.
    var fill: NSColor {
        colorLabel == 0
            ? .quaternaryLabelColor
            : NSColor.tagLabel(colorLabel).withAlphaComponent(Self.fillAlpha)
    }

    /// The name's size with its padding. The label's cell measures it: a truncating label's
    /// intrinsic width leaves out the cell's own 2 points either side, so a pill sized by it cuts
    /// the name short.
    override var fittingSize: NSSize {
        guard let cell = label.cell else { preconditionFailure("A text field has a cell") }
        let text = cell.cellSize
        return NSSize(
            width: (text.width + 2 * Self.padding.width).rounded(.up),
            height: (text.height + 2 * Self.padding.height).rounded(.up))
    }

    override func layout() {
        super.layout()
        label.frame = bounds.insetBy(dx: Self.padding.width, dy: Self.padding.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
            .fill()
    }
}
