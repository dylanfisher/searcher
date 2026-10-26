import AppKit
import Browser

/// One row of the palette: the item's icon for its kind, its title with the letters the query
/// matched in bold, its detail in secondary text, and, for a command, its chord right-aligned as
/// a menu shows it. A command that is off in the window is drawn greyed. VoiceOver reads the
/// title, the kind, the chord and whether it is unavailable.
@MainActor
final class PaletteCellView: NSTableCellView {
    let titleField = NSTextField(labelWithString: "")
    let detailField = NSTextField(labelWithString: "")
    let chordField = NSTextField(labelWithString: "")
    let icon = NSImageView()
    /// Whether the item can run; a command that is off can't.
    private(set) var isEnabled = true
    private var shown: Palette.Result?

    static let identifier = NSUserInterfaceItemIdentifier("palette")
    /// The height of a row whose title fits on one line: a line of system text with room around
    /// it, as Spotlight's rows have. A longer title wraps, and its row grows to fit it.
    static let rowHeight: CGFloat = 32
    /// The room above and below a title that wraps.
    static let wrappedPadding: CGFloat = 7
    /// The space between a wrapped title's lines, beyond the font's own leading, so the lines
    /// don't crowd each other.
    static let lineSpacing: CGFloat = 3
    private static let fontSize = NSFont.systemFontSize + 1
    private static let iconSize: CGFloat = 20
    /// How far the icon sits from the leading edge.
    private static let iconInset: CGFloat = 6
    /// The space between the icon, the title, the detail, the chord and the trailing edge.
    private static let spacing: CGFloat = 8

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleField.lineBreakMode = .byWordWrapping
        titleField.maximumNumberOfLines = 0
        titleField.cell?.wraps = true
        titleField.cell?.isScrollable = false
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        detailField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        chordField.font = .systemFont(ofSize: Self.fontSize)
        chordField.alignment = .right
        chordField.setContentCompressionResistancePriority(.required, for: .horizontal)
        icon.imageScaling = .scaleProportionallyUpOrDown
        // The cell's label says what the row is; its parts add nothing for VoiceOver.
        for field in [titleField, detailField, chordField] as [NSView] + [icon] {
            field.setAccessibilityElement(false)
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        imageView = icon
        textField = titleField
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.iconInset),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            titleField.leadingAnchor.constraint(
                equalTo: icon.trailingAnchor, constant: Self.spacing),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.leadingAnchor.constraint(
                equalTo: titleField.trailingAnchor, constant: Self.spacing),
            detailField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            chordField.leadingAnchor.constraint(
                greaterThanOrEqualTo: detailField.trailingAnchor, constant: Self.spacing),
            chordField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.spacing),
            chordField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.cell)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PaletteCellView is built in code")
    }

    /// Shows `result`, greyed unless `isEnabled`.
    func show(_ result: Palette.Result, isEnabled: Bool) {
        shown = result
        self.isEnabled = isEnabled
        let item = result.item
        icon.image =
            item.iconType.map { TypeIconCache.shared.icon(for: $0) } ?? Self.icon(for: item.kind)
        detailField.stringValue = item.detail ?? ""
        detailField.isHidden = item.detail == nil
        chordField.stringValue = item.chord?.symbols ?? ""
        chordField.isHidden = item.chord == nil
        var label = "\(item.title), \(Self.kindName(item.kind))"
        if let chord = item.chord { label += ", \(chord.symbols)" }
        if let detail = item.detail { label += ", \(detail)" }
        if !isEnabled { label += ", unavailable" }
        setAccessibilityLabel(label)
        restyle()
    }

    /// The title wraps at the width the cell's own width leaves it.
    override func layout() {
        wrapTitle(inCellOfWidth: bounds.width)
        super.layout()
    }

    /// The height of the row that shows `result` in a cell `width` wide: `rowHeight` for a
    /// title on one line, and a wrapped title's lines with `wrappedPadding` above and below.
    static func height(of result: Palette.Result, width: CGFloat) -> CGFloat {
        sizer.show(result, isEnabled: true)
        sizer.wrapTitle(inCellOfWidth: width)
        let title = sizer.titleField.intrinsicContentSize.height
        return max(rowHeight, (title + 2 * wrappedPadding).rounded(.up))
    }

    /// A cell that is never shown, which measures rows without a layout pass.
    private static let sizer = PaletteCellView()

    /// Wraps the title at the widest it can be in a cell `width` wide: all of it but the icon,
    /// the chord, the detail and the spaces between them. The detail keeps up to a third of the
    /// cell beside the title's first line, so a long name doesn't squeeze its kind to a letter.
    /// A wrapping field takes its width, and so its height, from `preferredMaxLayoutWidth`.
    private func wrapTitle(inCellOfWidth width: CGFloat) {
        let detail =
            detailField.isHidden ? 0 : min(detailField.intrinsicContentSize.width, width / 3)
        let others =
            Self.iconInset + Self.iconSize + 4 * Self.spacing
            + chordField.intrinsicContentSize.width + detail
        let wrapWidth = max(width - others, 0)
        if titleField.preferredMaxLayoutWidth != wrapWidth {
            titleField.preferredMaxLayoutWidth = wrapWidth
        }
    }

    /// The row's selection changed how it is drawn: on the accent colour, text is drawn in the
    /// selected text colour.
    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { restyle() }
    }

    private func restyle() {
        guard let result = shown else { return }
        let onAccent = backgroundStyle == .emphasized
        let selected = NSColor.alternateSelectedControlTextColor
        let primary: NSColor =
            onAccent
            ? isEnabled ? selected : selected.withAlphaComponent(0.5)
            : isEnabled ? .labelColor : .tertiaryLabelColor
        let secondary: NSColor =
            onAccent
            ? isEnabled ? selected : selected.withAlphaComponent(0.5)
            : isEnabled ? .secondaryLabelColor : .tertiaryLabelColor
        titleField.textColor = primary
        titleField.attributedStringValue = Self.title(of: result, color: primary)
        detailField.textColor = secondary
        chordField.textColor = secondary
        icon.alphaValue = isEnabled ? 1 : 0.5
    }

    private static let titleStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = lineSpacing
        return style
    }()

    /// `result`'s title, its matched letters bold.
    private static func title(of result: Palette.Result, color: NSColor) -> NSAttributedString {
        let title = result.item.title
        let text = NSMutableAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color,
                .paragraphStyle: titleStyle,
            ])
        let bold = NSFont.boldSystemFont(ofSize: fontSize)
        for range in result.ranges {
            text.addAttribute(.font, value: bold, range: NSRange(range, in: title))
        }
        return text
    }

    static func kindName(_ kind: PaletteItem.Kind) -> String {
        switch kind {
        case .workspace: "workspace"
        case .folder: "folder"
        case .command: "command"
        case .entry: "item"
        }
    }

    /// A folder's icon as Finder draws it; for a workspace, the window symbol the sidebar shows.
    /// An entry shows its type's icon instead, as the list does.
    private static func icon(for kind: PaletteItem.Kind) -> NSImage {
        let image: NSImage? =
            switch kind {
            case .folder: NSImage(named: NSImage.folderName)
            case .workspace:
                NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Workspace")
            case .command:
                NSImage(systemSymbolName: "command", accessibilityDescription: "Command")
            case .entry: preconditionFailure("an entry's item has no icon type")
            }
        guard let image else { preconditionFailure("the system has no image for a \(kind)") }
        return image
    }
}
