import AppKit
import Browser

/// Where a `ListingViewController`'s cells put their icon, name, badge and chevron: the sizes,
/// and the frames each takes from the cell's width and the room its chevron takes.
@MainActor
enum ListingCellLayout {
    /// The icon's side in the Name column, and where the name starts after it.
    static let iconSize = 16.0
    static let nameX = 2 + iconSize + 4

    /// The side of the badge, which is also the height of the chevron's view.
    static let badgeSize = 16.0
    /// The space between a name and its badge or chevron.
    static let badgeGap = 4.0
    /// The chevron's width, its image's (`TypeIconCache.folderChevron`).
    static let chevronWidth = 6.0

    /// The height of every cell's text field, a label's in `ListingViewController.nameFont`.
    static let labelHeight = NSTextField(labelWithString: "").intrinsicContentSize.height

    /// What a name's text field adds to the width of its text as `NSString.size(withAttributes:)`
    /// measures it in `ListingViewController.nameFont`: the field's own insets.
    static let nameFieldPadding: Double = {
        let sample = "M"
        let textWidth =
            (sample as NSString).size(withAttributes: [.font: ListingViewController.nameFont])
            .width
        return NSTextField(labelWithString: sample).intrinsicContentSize.width - textWidth
    }()

    /// How far past the cell's right edge the chevron's view ends in a table whose selection is
    /// `shape`. In the rounded band the glyph, which stops 1.5 points short of its image's right
    /// edge, ends 4.5 points inside the selection, 13.5 from the column's right edge, as
    /// Finder's does (second-column-rounded.jpg). Finder's trail's first column, whose
    /// selection runs the whole row, draws it further in, about 15.75 points from the column's
    /// right edge (first-column-square.jpg): its view ends at the cell's edge, so the glyph ends
    /// 15.5 points in. A point and a quarter isn't a whole pixel at 2x, where AppKit would
    /// round the view's frame and the name's width apart.
    private static func chevronOverhang(_ shape: ListingTableView.SelectionShape) -> Double {
        switch shape {
        case .roundedBand: 2
        case .fullWidth: 0
        }
    }

    /// The room the chevron's view takes inside the cell, from its right edge, in a table whose
    /// selection is `shape`.
    static func chevronRoom(for shape: ListingTableView.SelectionShape) -> Double {
        chevronWidth - chevronOverhang(shape)
    }

    /// Where a name cell `cellWidth` wide puts its badge: at its trailing edge, left of a
    /// chevron that takes `chevronRoom`, when it shows one.
    static func badgeX(cellWidth: Double, chevronRoom: Double?) -> Double {
        cellWidth - 2 - badgeSize - (chevronRoom.map { $0 - 2 + badgeGap } ?? 0)
    }

    /// Where the name ends in a name cell `cellWidth` wide: before the badge when it shows,
    /// else before a chevron that takes `chevronRoom` when it shows one, else at the trailing
    /// padding.
    static func nameEnd(cellWidth: Double, chevronRoom: Double?, badge: Bool) -> Double {
        if badge { return badgeX(cellWidth: cellWidth, chevronRoom: chevronRoom) - badgeGap }
        if let chevronRoom { return cellWidth - chevronRoom - badgeGap }
        return cellWidth - 2
    }

    /// Puts the name cell's badge and spinner left of its chevron when it shows one, else at its
    /// trailing edge, and fits the name to them. The chevron takes `chevronRoom` when it shows.
    static func fitBadgeAndName(in cell: NSTableCellView, chevronRoom: Double) {
        let x = badgeX(
            cellWidth: cell.bounds.width,
            chevronRoom: shownChevronRoom(cell, chevronRoom: chevronRoom))
        for view in [badge(in: cell), ListingViewController.connectingSpinner(in: cell)]
        where view.frame.minX != x {
            view.frame.origin.x = x
        }
        fitName(in: cell, chevronRoom: chevronRoom)
    }

    /// Puts a name cell's chevron `chevronRoom` in from the cell's right edge. A reused cell may
    /// come from before the table's selection changed shape.
    static func place(_ chevron: NSImageView, in cell: NSTableCellView, chevronRoom: Double) {
        let x = cell.bounds.width - chevronRoom
        if chevron.frame.minX != x {
            chevron.frame.origin.x = x
        }
    }

    static func chevron(in cell: NSTableCellView) -> NSImageView? {
        (cell as? ColumnNameCellView)?.chevron
    }

    /// `chevronRoom` when the cell shows its chevron, else nil.
    private static func shownChevronRoom(_ cell: NSTableCellView, chevronRoom: Double) -> Double? {
        chevron(in: cell).flatMap { $0.isHidden ? nil : chevronRoom }
    }

    /// Sets the name's width from the cell's: up to the badge when it shows, else up to the
    /// chevron, which takes `chevronRoom`, when it shows, else up to the trailing padding. Set
    /// outright, since autoresizing clamps a width at zero in a column narrower than the name and
    /// the badge, and widening the column doesn't give that back.
    static func fitName(in cell: NSTableCellView, chevronRoom: Double) {
        guard let textField = cell.textField else {
            preconditionFailure("the name cell has no text field: \(cell.subviews)")
        }
        let end = nameEnd(
            cellWidth: cell.bounds.width,
            chevronRoom: shownChevronRoom(cell, chevronRoom: chevronRoom),
            badge: !badge(in: cell).isHidden
                || !ListingViewController.connectingSpinner(in: cell).isHidden)
        let width = max(end - textField.frame.minX, 0)
        if textField.frame.width != width {
            textField.frame.size.width = width
        }
    }

    static func badge(in cell: NSTableCellView) -> NSImageView {
        guard
            let badge = cell.subviews.first(where: {
                $0.identifier == ListingViewController.notDownloadedBadgeIdentifier
            }) as? NSImageView
        else {
            preconditionFailure("the name cell has no badge view: \(cell.subviews)")
        }
        return badge
    }

    /// A cell of `column` in rows `height` tall, laid out with frames and autoresizing, which
    /// costs less per row than constraints. With `chevronImage` it is a column of column view's
    /// name cell, whose chevron takes `chevronRoom`.
    static func makeCell(
        for column: SortColumn, height: Double, chevronImage: NSImage?, chevronRoom: Double
    ) -> NSTableCellView {
        let frame = NSRect(x: 0, y: 0, width: column.width, height: height)
        let cell: NSTableCellView
        if let chevronImage {
            let named = ColumnNameCellView(frame: frame, chevronImage: chevronImage)
            let chevron = named.chevron
            chevron.identifier = ListingViewController.folderChevronIdentifier
            chevron.frame = NSRect(
                x: column.width - chevronRoom, y: (height - badgeSize) / 2, width: chevronWidth,
                height: badgeSize)
            chevron.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
            chevron.isHidden = true
            cell = named
        } else {
            cell = NSTableCellView(frame: frame)
        }
        cell.identifier = column.identifier
        var textX = 2.0
        if column == .name {
            let imageView = NSImageView(
                frame: NSRect(x: 2, y: (height - iconSize) / 2, width: iconSize, height: iconSize))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.minYMargin, .maxYMargin]
            // The icon repeats the Kind column, so VoiceOver reads the name alone.
            imageView.setAccessibilityElement(false)
            cell.addSubview(imageView)
            cell.imageView = imageView
            textX = nameX
        }
        let textField = NSTextField(labelWithString: "")
        textField.lineBreakMode = column == .name ? .byTruncatingMiddle : .byTruncatingTail
        textField.alignment = column.alignment
        textField.frame = NSRect(
            x: textX, y: (height - labelHeight) / 2, width: column.width - textX - 2,
            height: labelHeight)
        textField.autoresizingMask = [.width, .minYMargin, .maxYMargin]
        cell.addSubview(textField)
        cell.textField = textField
        if column == .name {
            // At the cell's trailing edge, as Finder draws it. Hidden until an entry needs it.
            // The row's label says the entry isn't downloaded, so the badge isn't read again.
            let badge = NSImageView(
                frame: NSRect(
                    x: column.width - 2 - badgeSize, y: (height - badgeSize) / 2,
                    width: badgeSize, height: badgeSize))
            badge.identifier = ListingViewController.notDownloadedBadgeIdentifier
            badge.imageScaling = .scaleProportionallyUpOrDown
            badge.contentTintColor = .secondaryLabelColor
            badge.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
            badge.setAccessibilityElement(false)
            badge.isHidden = true
            cell.addSubview(badge)
            // In the badge's place, for a share whose mount is taking a while.
            let spinner = NSProgressIndicator(frame: badge.frame)
            spinner.identifier = ListingViewController.connectingSpinnerIdentifier
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isDisplayedWhenStopped = false
            spinner.autoresizingMask = badge.autoresizingMask
            spinner.setAccessibilityLabel(ListingViewController.connectingLabel)
            spinner.isHidden = true
            cell.addSubview(spinner)
        }
        return cell
    }
}
