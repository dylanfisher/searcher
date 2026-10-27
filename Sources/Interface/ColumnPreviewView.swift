import AppKit
import Browser

/// Column view's preview of the one file selected in the last column, as Finder shows it: a large
/// type icon or the file's thumbnail, the name, its kind and size, then an Information section
/// with the created, modified and last-opened dates, then the tags. The name, kind, size and
/// modified date come from the column's listing and the icon is the type's shared one from
/// `TypeIconCache`, so they show at once; the rest is read, and the thumbnail made, off the main
/// thread, and column view shows a new file once they land, or without them after
/// `ColumnTrail.previewHold`, filling in later without moving the rows above. The icon or
/// thumbnail is scaled, as Finder's, to the width inside the insets, its edges on the fields',
/// or down from that to keep the fields below it in view; a thumbnail is the image alone, with
/// Finder's small rounded corners and no shadow. The rows are drawn as Finder's: title left, value right, a rule
/// under each. The name, the kind line, the values and the tags can be selected, not edited.
/// Built once and refilled for each file (0090-preview-column.md, 0095-preview-metadata.md,
/// 0102-thumbnails.md).
///
/// The fields scroll vertically when the column is shorter than they are. VoiceOver reads the
/// preview as a group named for the file, its text fields in reading order. It takes no keys.
@MainActor
final class ColumnPreviewView: NSView {
    /// Between the kind and the size under the name, as Finder writes it.
    static let summarySeparator = " – "
    static let informationTitle = "Information"
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
    /// The least the image is scaled down to in a window too short for it and the fields; the
    /// fields scroll below it then.
    static let smallestImageSide = 64.0
    /// The rounding of a thumbnail's corners, as Finder's preview draws a photo: a few points,
    /// with no shadow. A type icon, drawn by its own shape, isn't clipped.
    static let thumbnailCornerRadius: CGFloat = 7

    /// The longest side the image can be drawn at in a preview `width` by `height` points: the
    /// width inside the insets, or the height inside the margins.
    static func largestImageSide(width: Double, height: Double) -> Double {
        max(width - 2 * inset, height - 2 * margin)
    }

    /// Holds the fields, scrolling them vertically in a short window.
    let scrollView = NSScrollView()
    let iconView = NSImageView()
    let nameField = NSTextField(wrappingLabelWithString: "")
    /// The kind, and the size when the file has one.
    let summaryField = NSTextField(labelWithString: "")
    let createdField = ColumnPreviewView.value()
    let modifiedField = ColumnPreviewView.value()
    let lastOpenedField = ColumnPreviewView.value()
    /// The tags' names; hidden, with its title, when the file has none or they aren't read.
    let tagsField = NSTextField(wrappingLabelWithString: "")
    /// The Information rows, top to bottom: Created, Modified and Last opened, each its
    /// title left, its value right and a rule below it, as Finder draws them.
    let rows: [InformationRow]
    /// The file last shown, so a change that leaves it as it was sets no field.
    private(set) var shown: ColumnPreview?
    /// Gives the keys back to the focused column, from the preview's text: Esc, Tab and
    /// Shift-Tab pass nil, ↑ and ↓ their key press, which the column then takes as its own.
    var returnKeys: @MainActor (NSEvent?) -> Void = { _ in }

    /// The fields whose text can be selected: the name, the kind line, the values and the tags.
    var selectableFields: [NSTextField] {
        [nameField, summaryField] + rows.map(\.value) + [tagsField]
    }

    /// Whether one of the preview's fields has the keys, through the window's field editor.
    var textHasKeys: Bool {
        guard let editor = window?.firstResponder as? NSText,
            let field = editor.delegate as? NSTextField
        else { return false }
        return selectableFields.contains { $0 === field }
    }

    private let formatter: EntryCellFormatter
    private let iconCache: TypeIconCache
    private let informationField: NSTextField
    private let tagsTitleField: NSTextField
    /// The image and the fields under it, top to bottom.
    private let stack = NSStackView()
    /// The Information rows, in `stack`.
    private let rowStack = NSStackView()
    private lazy var imageWidth = iconView.widthAnchor.constraint(
        equalToConstant: ColumnPreview.defaultImageSide)
    private lazy var imageHeight = iconView.heightAnchor.constraint(
        equalToConstant: ColumnPreview.defaultImageSide)

    init(iconCache: TypeIconCache, formatter: EntryCellFormatter) {
        self.iconCache = iconCache
        self.formatter = formatter
        informationField = NSTextField(labelWithString: Self.informationTitle)
        tagsTitleField = NSTextField(labelWithString: Self.tagsTitle)
        rows = [
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
    /// without a size, such as a socket, shows only its kind under its name, as in Finder. The
    /// Created and Last opened rows are always there, empty until their dates are read; the
    /// tags sit below every other field.
    func show(_ preview: ColumnPreview) {
        guard preview != shown else { return }
        shown = preview
        let entry = preview.entry
        iconView.image =
            preview.thumbnail.map(NSImage.init(thumbnail:))
            ?? iconCache.icon(for: preview.kind.type)
        iconView.layer?.cornerRadius = preview.thumbnail == nil ? 0 : Self.thumbnailCornerRadius
        nameField.stringValue = entry.name
        let size = formatter.size(
            entry, folderSize: nil, showsFolderSizes: false, awaitsFolderSizes: false)
        let hasSize = entry.size != nil
        summaryField.stringValue =
            hasSize ? preview.kind.text + Self.summarySeparator + size : preview.kind.text
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
        sizeImage()
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
        sizeImage()
    }

    /// Sizes the image as Finder's preview does: as wide as the fields, at the image's aspect,
    /// unless that would push the Information rows below the preview's bottom, when it is scaled
    /// down to keep them in view, though to no less than `smallestImageSide`. The tags below
    /// the rows don't count, so the read that shows them moves nothing above them; they scroll.
    private func sizeImage() {
        let fieldsWidth = max(bounds.width - 2 * Self.inset, 0)
        let size = iconView.image?.size ?? .zero
        let aspect = size.width > 0 && size.height > 0 ? size.width / size.height : 1
        let room = bounds.height - 2 * Self.margin - fieldsHeight()
        let height = min(fieldsWidth / aspect, max(room, Self.smallestImageSide))
        let width = min(height * aspect, fieldsWidth).rounded()
        if imageWidth.constant != width { imageWidth.constant = width }
        if imageHeight.constant != height.rounded() { imageHeight.constant = height.rounded() }
    }

    /// The height of the fields from the image's bottom to the last Information row's, worked
    /// out from each field's own height at the wrap widths `setFrameSize` set and the stack's
    /// spacing, as the stack lays them out. Measuring each field's text costs a few
    /// microseconds; asking the stack for its fitting size solved its layout again, about 0.2 ms
    /// a call in a debug build, on every frame of a grip's drag.
    private func fieldsHeight() -> Double {
        let padding = Self.rowPadding
        let rows = rows.reduce(0.0) { sum, row in
            sum
                + max(
                    row.titleField.intrinsicContentSize.height,
                    row.value.intrinsicContentSize.height) + 2 * padding + 1
        }
        return [nameField, summaryField, informationField].reduce(
            stack.customSpacing(after: iconView) + rows
        ) { sum, field in
            sum + field.intrinsicContentSize.height + stack.customSpacing(after: field)
        }
    }

    private func build() {
        iconView.imageScaling = .scaleProportionallyUpOrDown
        // Clips a thumbnail to `thumbnailCornerRadius`. The image is sized to the frame's aspect
        // (`sizeImage`), so the clip falls on its corners.
        iconView.wantsLayer = true
        iconView.layer?.masksToBounds = true
        iconView.setAccessibilityElement(false)
        nameField.font = Self.nameFont
        summaryField.font = Self.detailFont
        summaryField.textColor = .secondaryLabelColor
        summaryField.lineBreakMode = .byTruncatingMiddle
        for header in [informationField, tagsTitleField] {
            header.font = Self.headerFont
        }
        tagsField.font = Self.detailFont
        // Finder's preview text can be selected and copied. A press on it takes the keys into
        // the text, which focuses the pane holding it; a press on the preview's empty space
        // gives the focused column the keys back (0090-preview-column.md).
        for field in [nameField, summaryField, tagsField] {
            field.isSelectable = true
            field.isEditable = false
        }
        for field in selectableFields { field.delegate = self }
        tagsTitleField.isHidden = true
        tagsField.isHidden = true

        for row in rows { rowStack.addArrangedSubview(row) }
        rowStack.orientation = .vertical
        rowStack.alignment = .leading
        rowStack.spacing = 0
        for view in [
            iconView, nameField, summaryField, informationField, rowStack, tagsTitleField,
            tagsField,
        ] {
            stack.addArrangedSubview(view)
        }
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
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: Self.margin),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -Self.margin),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: Self.inset),
            stack.trailingAnchor.constraint(
                equalTo: document.trailingAnchor, constant: -Self.inset),
            imageWidth, imageHeight,
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

    /// An Information row's value: wrapping, right-aligned, in the label color, selectable as
    /// Finder's is.
    private static func value() -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: "")
        field.font = detailFont
        field.alignment = .right
        field.isSelectable = true
        field.isEditable = false
        return field
    }

    /// The space at each side of the fields.
    private static let inset = 12.0
    /// The space above the image and below the last field.
    private static let margin = 24.0
}

extension ColumnPreviewView: NSTextFieldDelegate {
    /// Keys in the preview's selected text that would otherwise leave no way back to the
    /// columns by keyboard: Esc, Tab and Shift-Tab give the focused column the keys, and ↑ and
    /// ↓ give it the keys and move its selection, as they would have there. Shift-arrows still
    /// extend the text's selection, and Cmd-C copies it (0090-preview-column.md).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
        -> Bool
    {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)),
            #selector(NSResponder.insertBacktab(_:)):
            returnKeys(nil)
        case #selector(NSResponder.moveUp(_:)):
            returnKeys(Self.arrowPress(NSUpArrowFunctionKey, in: window))
        case #selector(NSResponder.moveDown(_:)):
            returnKeys(Self.arrowPress(NSDownArrowFunctionKey, in: window))
        default:
            return false
        }
        return true
    }

    /// The key press being handled when it is the arrow `key`, or else one made for it: a
    /// command can reach the field editor without a key press, as from a test.
    private static func arrowPress(_ key: Int, in window: NSWindow?) -> NSEvent? {
        let characters = String(Character(Unicode.Scalar(UInt16(key))!))
        if let event = NSApp.currentEvent, event.type == .keyDown,
            event.charactersIgnoringModifiers == characters
        {
            return event
        }
        return NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false,
            keyCode: key == NSUpArrowFunctionKey ? 126 : 125)
    }
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
