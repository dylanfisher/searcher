import AppKit
import Browser

/// A pane's folder as a row of buttons: the volume, then each folder down to the pane's. Clicking
/// a folder above the pane's reports it with the child on the way down, so the pane can select
/// the folder it came from; Cmd-clicking any folder, the pane's own too, asks for it in a new tab.
/// When the row doesn't fit, the folders between the ends shrink first. A segment under the mouse
/// gets a rounded grey highlight and, if it was shrunk, its full width while the others give way,
/// as in Finder's path bar. Which segment is under the mouse is read from the row as it lies with
/// none expanded, so expanding one never moves the mouse onto another. A segment still shrunk has
/// its full name as a tooltip.
///
/// It shows only the location and volume name it's given, and no icons, so it makes no
/// file-system call.
@MainActor
final class PathBarView: NSView {
    static let height: CGFloat = 28
    /// What VoiceOver calls the bar, before it reads the segments in it.
    static let label = "Path"
    /// The narrowest a segment gets before the ends shrink: about a letter and an ellipsis.
    static let minimumSegmentWidth: CGFloat = 32
    /// How far the hover highlight reaches above and below a segment's title.
    private static let highlightOutset: CGFloat = 2
    /// Room on each side of a chevron, so it doesn't touch a highlight.
    private static let separatorPadding: CGFloat = 1
    private static let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)

    /// Runs with the clicked folder and the name of its child on the path to the pane's folder.
    var onSelect: (@MainActor (Location, String) -> Void)?
    /// Runs with the Cmd-clicked folder.
    var onOpenInNewTab: (@MainActor (Location) -> Void)?
    /// The modifier keys held in the click being handled. Tests replace it.
    var currentModifierFlags: @MainActor () -> NSEvent.ModifierFlags = {
        NSApp?.currentEvent?.modifierFlags ?? []
    }

    /// The location shown; nil until the first `show`.
    private(set) var location: Location?
    private(set) var segments: [NSButton] = []
    private var rootVolumeName: String?
    private var ancestors: [Location] = []
    private var separators: [NSImageView] = []

    /// The index of the segment under the mouse, if any.
    private(set) var hoveredSegment: Int? {
        didSet {
            guard hoveredSegment != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A row too long even at the minimum widths runs past the edge; keep it inside the bar.
        clipsToBounds = true
        addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
                owner: self))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(Self.label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PathBarView is built in code")
    }

    /// Shows `location`, with `rootVolumeName` as the root's title. Does nothing if both are shown.
    func show(_ location: Location, rootVolumeName: String) {
        guard location != self.location || rootVolumeName != self.rootVolumeName else { return }
        self.location = location
        self.rootVolumeName = rootVolumeName
        for view in segments + separators {
            view.removeFromSuperview()
        }
        ancestors = location.ancestors
        hoveredSegment = nil
        segments = ancestors.enumerated().map { index, ancestor in
            let button = NSButton(
                title: index == 0 ? rootVolumeName : ancestor.name, target: self,
                action: #selector(segmentClicked(_:)))
            button.isBordered = false
            button.font = Self.font
            button.lineBreakMode = .byTruncatingMiddle
            button.tag = index
            return button
        }
        guard
            let chevron = NSImage(
                systemSymbolName: "chevron.right", accessibilityDescription: nil)?
                .withSymbolConfiguration(
                    .init(pointSize: Self.font.pointSize, weight: .semibold, scale: .small))
        else { preconditionFailure("SF Symbols has no chevron.right") }
        separators = segments.dropFirst().map { _ in
            let separator = NSImageView(image: chevron)
            separator.contentTintColor = .tertiaryLabelColor
            // Drawing between the buttons, with nothing for VoiceOver to read.
            separator.setAccessibilityElement(false)
            separator.cell?.setAccessibilityElement(false)
            return separator
        }
        for view in segments + separators {
            addSubview(view)
        }
        // The highlight reaches past its segment, so removing the segment leaves part of it.
        needsDisplay = true
        needsLayout = true
    }

    override func mouseEntered(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoveredSegment = nil
    }

    /// Hovers the segment whose span holds `point` with no segment expanded, or none over a
    /// separator or past the ends. Expanding a segment only shrinks the others, so its left edge
    /// is at or left of where it lies unexpanded and its right edge at or right of it: the mouse
    /// stays over the segment it expanded, and clicks reach that segment.
    func hover(at point: NSPoint) {
        let row = row(expanding: nil)
        hoveredSegment = segments.indices.first {
            point.x >= row.minXs[$0] && point.x < row.minXs[$0] + row.widths[$0]
        }
    }

    /// The segments' widths and left edges with the one at `expanding` given its room, the
    /// separators' sizes, and the segments' natural widths.
    private func row(expanding: Int?) -> (
        widths: [CGFloat], minXs: [CGFloat], separatorSizes: [NSSize], natural: [CGFloat]
    ) {
        // A view's intrinsic size is its alignment rect, which can be smaller than the frame its
        // content needs, so each separator gets the frame around that rect.
        let separatorSizes = separators.map {
            let size = $0.frame(
                forAlignmentRect: NSRect(origin: .zero, size: $0.intrinsicContentSize)
            ).size
            return NSSize(width: ceil(size.width) + 2 * Self.separatorPadding, height: size.height)
        }
        let natural = segments.map { ceil($0.intrinsicContentSize.width) }
        let widths = Self.widths(
            natural: natural,
            available: bounds.width - 2 * BarInset.horizontal
                - separatorSizes.map(\.width).reduce(0, +),
            minimum: Self.minimumSegmentWidth, expanding: expanding)
        var minXs: [CGFloat] = []
        var x = BarInset.horizontal
        for index in segments.indices {
            if index > 0 {
                x += separatorSizes[index - 1].width
            }
            minXs.append(x)
            x += widths[index]
        }
        return (widths, minXs, separatorSizes, natural)
    }

    override func layout() {
        super.layout()
        let (widths, minXs, separatorSizes, natural) = row(expanding: hoveredSegment)
        let oldFrames = segments.map(\.frame)
        defer {
            // A highlight drawn at a segment's old frame would stay behind.
            if segments.map(\.frame) != oldFrames { needsDisplay = true }
        }
        for (index, segment) in segments.enumerated() {
            segment.toolTip = widths[index] < natural[index] ? segment.title : nil
            // At its own height, so its baseline offset is where the title is drawn.
            let height = ceil(segment.intrinsicContentSize.height)
            segment.frame = NSRect(
                x: minXs[index], y: floor((bounds.height - height) / 2), width: widths[index],
                height: height)
        }
        // Centered on the middle of a capital letter rather than on the bar, so the chevrons sit
        // level with the titles at any font size.
        guard let first = segments.first else { return }
        let baseline = first.frame.maxY - first.firstBaselineOffsetFromTop
        let textMiddle = baseline + Self.font.capHeight / 2
        for (index, separator) in separators.enumerated() {
            let height = ceil(separatorSizes[index].height)
            separator.frame = NSRect(
                x: segments[index].frame.maxX, y: (textMiddle - height / 2).rounded(),
                width: separatorSizes[index].width, height: height)
        }
    }

    /// Where the hover highlight is drawn, if a segment is hovered.
    var highlightFrame: NSRect? {
        hoveredSegment.map { segments[$0].frame.insetBy(dx: 0, dy: -Self.highlightOutset) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let frame = highlightFrame else { return }
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: frame, xRadius: 4, yRadius: 4).fill()
    }

    /// Each segment's width when `natural` must fit in `available`. The segments between the ends
    /// shrink to `minimum` first, the one nearest the root first, then the root, then the last.
    /// Widths that still don't fit stay at the minimum, and the bar clips the row. The segment at
    /// `expanding`, the hovered one, shrinks only after all the others are at the minimum.
    nonisolated static func widths(
        natural: [CGFloat], available: CGFloat, minimum: CGFloat, expanding: Int? = nil
    ) -> [CGFloat] {
        var widths = natural
        var excess = natural.reduce(0, +) - available
        let order =
            (Array(natural.indices.dropFirst().dropLast()) + (natural.isEmpty ? [] : [0])
            + (natural.count > 1 ? [natural.count - 1] : []))
            .filter { $0 != expanding } + (expanding.map { [$0] } ?? [])
        for index in order where excess > 0 {
            let cut = min(excess, max(widths[index] - minimum, 0))
            widths[index] -= cut
            excess -= cut
        }
        return widths
    }

    @objc private func segmentClicked(_ sender: NSButton) {
        let index = sender.tag
        if currentModifierFlags().contains(.command) {
            onOpenInNewTab?(ancestors[index])
            return
        }
        guard index < ancestors.count - 1 else { return }
        onSelect?(ancestors[index], ancestors[index + 1].name)
    }
}
