import AppKit
import Browser

/// Column view's preview of the one file selected in the last column, as Finder shows it: a large
/// type icon, the name, its kind and size, then an Information section with the size and the
/// modification date. Every field comes from the column's listing, so showing a file reads
/// nothing, and the icon is the type's shared one from `TypeIconCache`. Built once and refilled
/// for each file (0090-preview-column.md).
///
/// VoiceOver reads it as a group named for the file, its text fields in reading order. It takes
/// no keys.
@MainActor
final class ColumnPreviewView: NSView {
    /// The side of the type icon.
    static let iconSide = 128.0
    /// Between the kind and the size under the name, as Finder writes it.
    static let summarySeparator = " – "
    static let informationTitle = "Information"
    static let sizeTitle = "Size"
    static let modifiedTitle = "Modified"

    let iconView = NSImageView()
    let nameField = NSTextField(wrappingLabelWithString: "")
    /// The kind, and the size when the file has one.
    let summaryField = NSTextField(labelWithString: "")
    let sizeField = NSTextField(labelWithString: "")
    let modifiedField = NSTextField(labelWithString: "")
    /// The file last shown, so a change that leaves it as it was sets no field.
    private(set) var shown: ColumnPreview?

    private let formatter: EntryCellFormatter
    private let iconCache: TypeIconCache

    init(iconCache: TypeIconCache, formatter: EntryCellFormatter) {
        self.iconCache = iconCache
        self.formatter = formatter
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnPreviewView is built in code")
    }

    /// Fills the fields from `preview`. Does nothing when it is the file already shown.
    func show(_ preview: ColumnPreview) {
        guard preview != shown else { return }
        shown = preview
        let entry = preview.entry
        iconView.image = iconCache.icon(for: preview.kind.type)
        nameField.stringValue = entry.name
        let size = formatter.size(
            entry, folderSize: nil, showsFolderSizes: false, awaitsFolderSizes: false)
        summaryField.stringValue =
            entry.size == nil ? preview.kind.text : preview.kind.text + Self.summarySeparator + size
        sizeField.stringValue = size
        modifiedField.stringValue = formatter.date(entry.modified)
        setAccessibilityLabel(entry.name)
    }

    private func build() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        nameField.alignment = .center
        nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        nameField.preferredMaxLayoutWidth = ColumnViewController.columnWidth - 2 * Self.inset
        summaryField.alignment = .center
        summaryField.textColor = .secondaryLabelColor
        summaryField.lineBreakMode = .byTruncatingMiddle
        let information = NSTextField(labelWithString: Self.informationTitle)
        information.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let sizeTitle = Self.title(Self.sizeTitle)
        let modifiedTitle = Self.title(Self.modifiedTitle)
        for value in [sizeField, modifiedField] {
            value.lineBreakMode = .byTruncatingTail
        }
        let grid = NSGridView(views: [[sizeTitle, sizeField], [modifiedTitle, modifiedField]])
        grid.column(at: 0).xPlacement = .trailing
        grid.columnSpacing = 6
        grid.rowSpacing = 4
        grid.column(at: 1).xPlacement = .leading

        let stack = NSStackView(views: [iconView, nameField, summaryField, information, grid])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: iconView)
        stack.setCustomSpacing(16, after: summaryField)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            information.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren([
            nameField, summaryField, information, sizeTitle, sizeField, modifiedTitle,
            modifiedField,
        ])
    }

    /// A row's title in the Information section, in secondary text.
    private static func title(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.textColor = .secondaryLabelColor
        field.alignment = .right
        return field
    }

    /// The space at each side of the fields.
    private static let inset = 12.0
}
