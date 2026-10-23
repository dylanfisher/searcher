import AppKit
import Browser

/// A pane's folder as a row of buttons: the volume, then each folder down to the pane's. Clicking
/// a folder above the pane's reports it with the child on the way down, so the pane can select
/// the folder it came from; Cmd-clicking any folder, the pane's own too, asks for it in a new tab.
/// When the row doesn't fit, the folders between the ends shrink first.
///
/// It shows only the location and volume name it's given, and no icons, so it makes no
/// file-system call.
@MainActor
final class PathBarView: NSView {
    static let height: CGFloat = 24
    /// What VoiceOver calls the bar, before it reads the segments in it.
    static let label = "Path"
    /// The narrowest a segment gets before the ends shrink: about a letter and an ellipsis.
    static let minimumSegmentWidth: CGFloat = 32
    private static let inset: CGFloat = 6

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
    private var separators: [NSTextField] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A row too long even at the minimum widths runs past the edge; keep it inside the bar.
        clipsToBounds = true
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
        segments = ancestors.enumerated().map { index, ancestor in
            let button = NSButton(
                title: index == 0 ? rootVolumeName : ancestor.name, target: self,
                action: #selector(segmentClicked(_:)))
            button.isBordered = false
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.lineBreakMode = .byTruncatingMiddle
            button.tag = index
            return button
        }
        separators = segments.dropFirst().map { _ in
            let separator = NSTextField(labelWithString: "›")
            separator.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            separator.textColor = .tertiaryLabelColor
            // Drawing between the buttons; VoiceOver would read it as a quotation mark. A
            // control's accessibility element is its cell, so the cell is the one hidden.
            separator.cell?.setAccessibilityElement(false)
            return separator
        }
        for view in segments + separators {
            addSubview(view)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let separatorWidths = separators.map { ceil($0.intrinsicContentSize.width) }
        let widths = Self.widths(
            natural: segments.map { ceil($0.intrinsicContentSize.width) },
            available: bounds.width - 2 * Self.inset - separatorWidths.reduce(0, +),
            minimum: Self.minimumSegmentWidth)
        var x = Self.inset
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                let separator = separators[index - 1]
                separator.frame = centered(separator, x: x, width: separatorWidths[index - 1])
                x += separatorWidths[index - 1]
            }
            segment.frame = centered(segment, x: x, width: widths[index])
            x += widths[index]
        }
    }

    private func centered(_ view: NSView, x: CGFloat, width: CGFloat) -> NSRect {
        let height = ceil(view.intrinsicContentSize.height)
        return NSRect(x: x, y: floor((bounds.height - height) / 2), width: width, height: height)
    }

    /// Each segment's width when `natural` must fit in `available`. The segments between the ends
    /// shrink to `minimum` first, the one nearest the root first, then the root, then the last.
    /// Widths that still don't fit stay at the minimum, and the bar clips the row.
    nonisolated static func widths(natural: [CGFloat], available: CGFloat, minimum: CGFloat)
        -> [CGFloat]
    {
        var widths = natural
        var excess = natural.reduce(0, +) - available
        let order =
            Array(natural.indices.dropFirst().dropLast()) + (natural.isEmpty ? [] : [0])
            + (natural.count > 1 ? [natural.count - 1] : [])
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
