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
    /// The row's height: a line of system text with room around it, as Spotlight's rows have.
    static let rowHeight: CGFloat = 32
    private static let fontSize = NSFont.systemFontSize + 1
    private static let iconSize: CGFloat = 20

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        titleField.lineBreakMode = .byTruncatingMiddle
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
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconSize),
            titleField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailField.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),
            detailField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            chordField.leadingAnchor.constraint(
                greaterThanOrEqualTo: detailField.trailingAnchor, constant: 8),
            chordField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
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
        icon.image = Self.icon(for: item.kind)
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

    /// `result`'s title, its matched letters bold.
    private static func title(of result: Palette.Result, color: NSColor) -> NSAttributedString {
        let title = result.item.title
        let text = NSMutableAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: color])
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
        }
    }

    /// A folder's icon as Finder draws it; for a workspace, the window symbol the sidebar shows.
    private static func icon(for kind: PaletteItem.Kind) -> NSImage {
        let image: NSImage? =
            switch kind {
            case .folder: NSImage(named: NSImage.folderName)
            case .workspace:
                NSImage(systemSymbolName: "macwindow", accessibilityDescription: "Workspace")
            case .command:
                NSImage(systemSymbolName: "command", accessibilityDescription: "Command")
            }
        guard let image else { preconditionFailure("the system has no image for a \(kind)") }
        return image
    }
}
