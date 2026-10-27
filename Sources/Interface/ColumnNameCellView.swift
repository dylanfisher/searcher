import AppKit

/// A name cell of a column in column view: the list's name cell plus the chevron Finder draws at
/// the right of a folder row. The chevron is a template that takes its tint from the row's
/// background style, as the name beside it takes its text color: white on a selected row in the
/// column that has the keys, the secondary label color otherwise.
final class ColumnNameCellView: ListingNameCellView {
    let chevron = NSImageView()

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { tintChevron() }
    }

    init(frame: NSRect, chevronImage: NSImage) {
        super.init(frame: frame)
        chevron.image = chevronImage
        chevron.imageScaling = .scaleNone
        chevron.setAccessibilityElement(false)
        tintChevron()
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ColumnNameCellView is built in code")
    }

    private func tintChevron() {
        chevron.contentTintColor =
            backgroundStyle == .emphasized
            ? .alternateSelectedControlTextColor : .secondaryLabelColor
    }
}
