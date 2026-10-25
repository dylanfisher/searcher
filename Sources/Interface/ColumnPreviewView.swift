import AppKit
import Browser

/// Column view's preview of the one file selected in the last column, as Finder shows it: a large
/// type icon, the name, its kind and size, then an Information section with the size and the
/// created, modified and last-opened dates, then the tags. The name, kind, size and modified date
/// come from the column's listing and the icon is the type's shared one from `TypeIconCache`, so
/// they show at once; the rest is read off the main thread, and column view shows a new file once
/// it lands, or empty after `ColumnTrail.previewHold`, filling in later without moving the rows
/// above. The rows are drawn as Finder's: title left, value right, a rule under each. Built once
/// and refilled for each file (0090-preview-column.md, 0095-preview-metadata.md).
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
    /// The name's type, as Finder's preview sets it: bold, larger than the rest.
    static let nameFont = NSFont.boldSystemFont(ofSize: 15)
    /// The section headers', Information and Tags.
    static let headerFont = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    /// The kind and size under the name, and each Information row's title and value.
    static let detailFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
    /// The space above and below an Information row's text, inside the rules between rows.
    static let rowPadding = 4.0

    /// Holds the fields, scrolling them vertically in a short window.
    let scrollView = NSScrollView()
    let iconView = NSImageView()
    let nameField = NSTextField(wrappingLabelWithString: "")
    /// The kind, and the size when the file has one.
    let summaryField = NSTextField(labelWithString: "")
    let sizeField = ColumnPreviewView.value()
    let createdField = ColumnPreviewView.value()
    let modifiedField = ColumnPreviewView.value()
    let lastOpenedField = ColumnPreviewView.value()
    /// The tags' names; hidden, with its title, when the file has none or they aren't read.
    let tagsField = NSTextField(wrappingLabelWithString: "")
    /// The Information rows, top to bottom: Size, Created, Modified and Last opened, each its
    /// title left, its value right and a rule below it, as Finder draws them.
    let rows: [InformationRow]
    /// The file last shown, so a change that leaves it as it was sets no field.
    private(set) var shown: ColumnPreview?

    private let formatter: EntryCellFormatter
    private let iconCache: TypeIconCache
    private let informationField: NSTextField
    private let tagsTitleField: NSTextField

    init(iconCache: TypeIconCache, formatter: EntryCellFormatter) {
        self.iconCache = iconCache
        self.formatter = formatter
        informationField = NSTextField(labelWithString: Self.informationTitle)
        tagsTitleField = NSTextField(labelWithString: Self.tagsTitle)
        rows = [
            InformationRow(title: Self.sizeTitle, value: sizeField),
            InformationRow(title: Self.createdTitle, value: createdField),
            InformationRow(title: Self.modifiedTitle, value: modifiedField),
            InformationRow(title: Self.lastOpenedTitle, value: lastOpenedField),
        ]
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnPreviewView is built in code")
    }

    /// Fills the fields from `preview`. Does nothing when it is the file already shown. An entry
    /// without a size, such as a socket, shows its kind and no Size row, as in Finder. The
    /// Created and Last opened rows are always there, empty until their dates are read; the
    /// tags sit below every other field.
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
        rows[0].isShown = hasSize
        modifiedField.stringValue = formatter.longDate(entry.modified)
        let tags: [String]
        switch preview.info {
        case .unread, .reading:
            createdField.stringValue = ""
            lastOpenedField.stringValue = ""
            tags = []
        case .read(let info):
            createdField.stringValue = info.created.map(formatter.longDate) ?? Self.noDate
            lastOpenedField.stringValue = info.lastOpened.map(formatter.longDate) ?? Self.noDate
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

    /// Wraps the name, the rows' values and the tags at the preview's width, which its grip
    /// changes.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let wrapWidth = max(newSize.width - 2 * Self.inset, 0)
        for field in [nameField, tagsField] where field.preferredMaxLayoutWidth != wrapWidth {
            field.preferredMaxLayoutWidth = wrapWidth
        }
        for row in rows { row.wrapValue(at: wrapWidth) }
    }

    private func build() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityElement(false)
        nameField.font = Self.nameFont
        summaryField.font = Self.detailFont
        summaryField.textColor = .secondaryLabelColor
        summaryField.lineBreakMode = .byTruncatingMiddle
        for header in [informationField, tagsTitleField] {
            header.font = Self.headerFont
        }
        tagsField.font = Self.detailFont
        tagsTitleField.isHidden = true
        tagsField.isHidden = true

        let rowStack = NSStackView(views: rows)
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        let stack = NSStackView(views: [
            iconView, nameField, summaryField, informationField, rowStack, tagsTitleField,
            tagsField,
        ])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.setCustomSpacing(12, after: iconView)
        stack.setCustomSpacing(2, after: nameField)
        stack.setCustomSpacing(16, after: summaryField)
        stack.setCustomSpacing(2, after: informationField)
        stack.setCustomSpacing(16, after: rowStack)
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
            nameField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            summaryField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            informationField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            rowStack.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            tagsTitleField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            tagsField.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
        ]
        for row in rows {
            constraints.append(row.widthAnchor.constraint(equalTo: rowStack.widthAnchor))
        }
        // A view in a centering stack can be wider than the stack; these keep each field inside
        // it, truncating or wrapping the text instead.
        for field in [nameField, summaryField, informationField, tagsTitleField, tagsField] {
            constraints.append(field.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor))
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        NSLayoutConstraint.activate(constraints)

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityChildren(readingOrder())
    }

    /// The text fields VoiceOver reads, in order: the ones shown.
    private func readingOrder() -> [NSTextField] {
        ([nameField, summaryField, informationField] + rows.flatMap { [$0.titleField, $0.value] }
            + [tagsTitleField, tagsField]).filter { !$0.isHidden }
    }

    /// An Information row's value: wrapping, right-aligned, in the label color.
    private static func value() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = detailFont
        field.alignment = .right
        return field
    }

    /// The space at each side of the fields.
    private static let inset = 12.0
}

/// One row of the preview's Information section, as Finder draws it: its title at the left in
/// secondary text, its value at the right, wrapping when the two don't fit on a line, and a thin
/// rule in the separator color under the row.
@MainActor
final class InformationRow: NSView {
    /// Between the title and the value.
    static let gap = 8.0

    let titleField: NSTextField
    let value: NSTextField
    /// The rule under the row.
    let rule = NSBox()

    init(title: String, value: NSTextField) {
        titleField = NSTextField(labelWithString: title)
        self.value = value
        super.init(frame: .zero)
        titleField.font = ColumnPreviewView.detailFont
        titleField.textColor = .secondaryLabelColor
        rule.boxType = .separator
        rule.setAccessibilityElement(false)
        let padding = ColumnPreviewView.rowPadding
        for view in [titleField, value, rule] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        translatesAutoresizingMaskIntoConstraints = false
        titleField.setContentCompressionResistancePriority(.required, for: .horizontal)
        titleField.setContentHuggingPriority(.required, for: .horizontal)
        value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            value.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            value.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleField.trailingAnchor, constant: Self.gap),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(
                greaterThanOrEqualTo: titleField.bottomAnchor, constant: padding),
            rule.topAnchor.constraint(greaterThanOrEqualTo: value.bottomAnchor, constant: padding),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
        ])
        // The row is as short as its text lets it be.
        let fit = rule.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: padding)
        fit.priority = .defaultLow
        fit.isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("InformationRow is built in code")
    }

    /// Whether the row shows. A hidden row's fields are hidden too, so VoiceOver skips them.
    var isShown: Bool {
        get { !isHidden }
        set {
            guard newValue == isHidden else { return }
            isHidden = !newValue
            titleField.isHidden = !newValue
            value.isHidden = !newValue
        }
    }

    /// Wraps the value at what `width`, the row's, leaves beside the title.
    func wrapValue(at width: Double) {
        let valueWidth = max(width - titleField.intrinsicContentSize.width - Self.gap, 0)
        if value.preferredMaxLayoutWidth != valueWidth {
            value.preferredMaxLayoutWidth = valueWidth
        }
    }
}

/// The scrolled fields' document view, flipped so the fields start at the top.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
