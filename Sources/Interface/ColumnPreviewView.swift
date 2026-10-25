import AppKit
import Browser

/// Column view's preview of the one file selected in the last column, as Finder shows it: a large
/// type icon, the name, its kind and size, then an Information section with the size and the
/// created, modified and last-opened dates, then the tags. The name, kind, size and modified date
/// come from the column's listing and the icon is the type's shared one from `TypeIconCache`, so
/// they show at once; the rest is read off the main thread and fills in when it lands, without
/// moving a field. Built once and refilled for each file (0090-preview-column.md,
/// 0095-preview-metadata.md).
///
/// The fields scroll vertically when the column is shorter than they are. VoiceOver reads the
/// preview as a group named for the file, its text fields in reading order. It takes no keys.
@MainActor
final class ColumnPreviewView: NSView {
    /// The side of the type icon.
    static let iconSide = 128.0
    /// Between the kind and the size under the name, as Finder writes it.
    static let summarySeparator = " – "
    static let informationTitle = "Information"
    static let sizeTitle = "Size"
    static let createdTitle = "Created"
    static let modifiedTitle = "Modified"
    static let lastOpenedTitle = "Last opened"
    static let tagsTitle = "Tags"
    /// A date that was read and isn't there, or a read that failed, as Finder shows an unknown
    /// value.
    static let noDate = "--"
    /// Between two tags' names.
    static let tagSeparator = ", "

    /// Holds the fields, scrolling them vertically in a short window.
    let scrollView = NSScrollView()
    let iconView = NSImageView()
    let nameField = NSTextField(wrappingLabelWithString: "")
    /// The kind, and the size when the file has one.
    let summaryField = NSTextField(labelWithString: "")
    let sizeField = NSTextField(labelWithString: "")
    let createdField = NSTextField(labelWithString: "")
    let modifiedField = NSTextField(labelWithString: "")
    let lastOpenedField = NSTextField(labelWithString: "")
    /// The tags' names; hidden, with its title, when the file has none or they aren't read.
    let tagsField = NSTextField(wrappingLabelWithString: "")
    /// The file last shown, so a change that leaves it as it was sets no field.
    private(set) var shown: ColumnPreview?

    private let formatter: EntryCellFormatter
    private let iconCache: TypeIconCache
    private let informationField: NSTextField
    private let sizeTitleField: NSTextField
    private let createdTitleField: NSTextField
    private let modifiedTitleField: NSTextField
    private let lastOpenedTitleField: NSTextField
    private let tagsTitleField: NSTextField
    private let grid: NSGridView

    init(iconCache: TypeIconCache, formatter: EntryCellFormatter) {
        self.iconCache = iconCache
        self.formatter = formatter
        informationField = NSTextField(labelWithString: Self.informationTitle)
        sizeTitleField = Self.title(Self.sizeTitle)
        createdTitleField = Self.title(Self.createdTitle)
        modifiedTitleField = Self.title(Self.modifiedTitle)
        lastOpenedTitleField = Self.title(Self.lastOpenedTitle)
        tagsTitleField = NSTextField(labelWithString: Self.tagsTitle)
        grid = NSGridView(views: [
            [sizeTitleField, sizeField], [createdTitleField, createdField],
            [modifiedTitleField, modifiedField], [lastOpenedTitleField, lastOpenedField],
        ])
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnPreviewView is built in code")
    }

    /// Fills the fields from `preview`. Does nothing when it is the file already shown. An entry
    /// without a size, such as a socket, shows its kind and no Size row, as in Finder. The
    /// Created and Last opened rows are always there, empty until their dates are read, so a
    /// read landing moves nothing; the tags sit below every other field.
    func show(_ preview: ColumnPreview) {
        guard preview != shown else { return }
        shown = preview
        let entry = preview.entry
        iconView.image = iconCache.icon(for: preview.kind.type)
        nameField.stringValue = entry.name
        let size = formatter.size(
            entry, folderSize: nil, showsFolderSizes: false, awaitsFolderSizes: false)
        let hasSize = entry.size != nil
        summaryField.stringValue =
            hasSize ? preview.kind.text + Self.summarySeparator + size : preview.kind.text
        sizeField.stringValue = size
        if grid.row(at: 0).isHidden == hasSize {
            grid.row(at: 0).isHidden = !hasSize
            sizeTitleField.isHidden = !hasSize
            sizeField.isHidden = !hasSize
        }
        modifiedField.stringValue = formatter.date(entry.modified)
        let tags: [String]
        switch preview.info {
        case .unread, .reading:
            createdField.stringValue = ""
            lastOpenedField.stringValue = ""
            tags = []
        case .read(let info):
            createdField.stringValue = info.created.map(formatter.date) ?? Self.noDate
            lastOpenedField.stringValue = info.lastOpened.map(formatter.date) ?? Self.noDate
            tags = info.tags
        case .failed:
            createdField.stringValue = Self.noDate
            lastOpenedField.stringValue = Self.noDate
            tags = []
        }
        tagsField.stringValue = tags.joined(separator: Self.tagSeparator)
        tagsTitleField.isHidden = tags.isEmpty
        tagsField.isHidden = tags.isEmpty
        setAccessibilityChildren(readingOrder())
        setAccessibilityLabel(entry.name)
    }

    /// Wraps the name and the tags at the preview's width, which its grip changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let wrapWidth = max(newSize.width - 2 * Self.inset, 0)
        for field in [nameField, tagsField] where field.preferredMaxLayoutWidth != wrapWidth {
            field.preferredMaxLayoutWidth = wrapWidth
        }
    }

    private func build() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        nameField.alignment = .center
        nameField.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        summaryField.alignment = .center
        summaryField.textColor = .secondaryLabelColor
        summaryField.lineBreakMode = .byTruncatingMiddle
        for header in [informationField, tagsTitleField] {
            header.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        }
        tagsTitleField.isHidden = true
        tagsField.isHidden = true
        for value in [sizeField, createdField, modifiedField, lastOpenedField] {
            value.lineBreakMode = .byTruncatingTail
        }
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        grid.columnSpacing = 6
        grid.rowSpacing = 4

        let stack = NSStackView(views: [
            iconView, nameField, summaryField, informationField, grid, tagsTitleField, tagsField,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: iconView)
        stack.setCustomSpacing(16, after: summaryField)
        stack.setCustomSpacing(16, after: grid)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        let clip = scrollView.contentView
        iconView.translatesAutoresizingMaskIntoConstraints = false
        var constraints = [
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(
                equalTo: document.trailingAnchor, constant: -Self.inset),
            iconView.widthAnchor.constraint(equalToConstant: Self.iconSide),
            iconView.heightAnchor.constraint(equalToConstant: Self.iconSide),
            informationField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            grid.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: stack.trailingAnchor),
            tagsTitleField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            tagsField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        ]
        // A centered view in a stack can be wider than the stack; these keep each field inside
        // it, truncating or wrapping the text instead.
        for field in [nameField, summaryField, informationField, tagsTitleField, tagsField] {
            constraints.append(field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor))
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for field in [sizeField, createdField, modifiedField, lastOpenedField] {
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate(constraints)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren(readingOrder())
    }

    /// The text fields VoiceOver reads, in order: the ones shown.
    private func readingOrder() -> [NSTextField] {
        [
            nameField, summaryField, informationField, sizeTitleField, sizeField,
            createdTitleField, createdField, modifiedTitleField, modifiedField,
            lastOpenedTitleField, lastOpenedField, tagsTitleField, tagsField,
        ].filter { !$0.isHidden }
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

/// The scrolled fields' document view, flipped so the fields start at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
