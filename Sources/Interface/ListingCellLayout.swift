import AppKit
import Browser

/// Where a `ListingViewController`'s cells put their icon, name, badge and chevron: the sizes,
/// and the frames each takes from the cell's width and the room its chevron takes.
@MainActor
enum ListingCellLayout {
    /// A row's height, the icon's side in the Name column, and where the name starts after it.
    /// The icon's left edge is 2 points into the cell in both views.
    struct Rows: Equatable {
        let height: Double
        let iconSize: Double
        /// From the icon's right edge to the name's text field.
        let iconGap: Double

        var nameX: Double { 2 + iconSize + iconGap }
    }

    /// Finder's list view on macOS 26, at its default 16 × 16 icon size: 20-point rows, a
    /// 16-point icon and the name 3 points after it (fb-1029-1.jpg;
    /// docs/decisions/0135-list-rows-as-finder.md).
    static let listRows = Rows(height: 20, iconSize: 16, iconGap: 3)
    /// Finder's column view on macOS 26: 24-point rows, an 18-point icon, which draws the icon's
    /// 18-point artwork, and the name 3.5 points after it (fb-1028b-1.jpg;
    /// docs/decisions/0129-row-icons-as-finder.md).
    static let columnRows = Rows(height: 24, iconSize: 18, iconGap: 3.5)

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

    /// Where a name cell `cellWidth` wide puts its eject button: at its trailing edge, or
    /// ending where a chevron that takes `chevronRoom` starts, when it shows one. The glyph sits
    /// in the middle of the button, so it ends about 6 points before the cell's edge or the
    /// chevron, as Finder's does (docs/decisions/0118-row-eject-buttons.md).
    static func ejectX(cellWidth: Double, chevronRoom: Double?) -> Double {
        cellWidth - (chevronRoom ?? 0) - HoverButton.side
    }

    /// The space between a column's tag dots and the room its chevron takes, which puts the dots
    /// where Finder's are: their middle about 13 points left of the chevron's
    /// (docs/decisions/0124-tags-in-rows-and-preview.md).
    static let tagDotsGap = 6.0

    /// The furthest right a row's tag dots end in a name cell `cellWidth` wide: before the eject
    /// button when it shows, else before the badge when it shows, else, in a column, before the
    /// room a folder's chevron takes, `columnChevronRoom`, whether or not the row shows one, so
    /// the dots of files and folders line up as Finder's do; else at the trailing padding. The
    /// eject button and the badge sit left of a chevron that takes `chevronRoom` when it shows.
    static func tagDotsEnd(
        cellWidth: Double, columnChevronRoom: Double?, chevronRoom: Double?, badge: Bool,
        eject: Bool
    ) -> Double {
        if eject { return ejectX(cellWidth: cellWidth, chevronRoom: chevronRoom) }
        if badge { return badgeX(cellWidth: cellWidth, chevronRoom: chevronRoom) - badgeGap }
        return columnChevronRoom.map { cellWidth - $0 - tagDotsGap } ?? cellWidth - 2
    }

    /// Where a row's tag dots, `width` wide, start: a gap after the name, whose label starts at
    /// `nameX` and is `nameWidth` wide, as Finder puts them, or further left to end by `end`, the
    /// name truncating before them.
    static func tagDotsX(nameX: Double, nameWidth: Double, width: Double, end: Double) -> Double {
        min(nameX + nameWidth + badgeGap, end - width)
    }

    /// The width of the label showing `name` whole, in `ListingViewController.nameFont`.
    static func nameWidth(_ name: String) -> Double {
        let text = (name as NSString).size(withAttributes: [.font: ListingViewController.nameFont])
        return (text.width + nameFieldPadding).rounded(.up)
    }

    /// Where the name ends in a name cell `cellWidth` wide: before tag dots that start at
    /// `tagDotsX` when it shows them, else before the eject button when it shows, else before
    /// the badge when it shows, else before a chevron that takes `chevronRoom` when it shows
    /// one, else at the trailing padding. A row with an eject button is a volume's, which has no
    /// badge.
    static func nameEnd(
        cellWidth: Double, chevronRoom: Double?, badge: Bool, eject: Bool = false,
        tagDotsX: Double? = nil
    ) -> Double {
        if let tagDotsX { return tagDotsX - badgeGap }
        if eject { return ejectX(cellWidth: cellWidth, chevronRoom: chevronRoom) }
        if badge { return badgeX(cellWidth: cellWidth, chevronRoom: chevronRoom) - badgeGap }
        if let chevronRoom { return cellWidth - chevronRoom - badgeGap }
        return cellWidth - 2
    }

    /// Puts the name cell's badge, spinner and eject button left of its chevron when it shows
    /// one, else at its trailing edge, and fits the name to them. The chevron takes
    /// `chevronRoom` when it shows.
    static func fitBadgeAndName(in cell: NSTableCellView, chevronRoom: Double) {
        let shownRoom = shownChevronRoom(cell, chevronRoom: chevronRoom)
        let x = badgeX(cellWidth: cell.bounds.width, chevronRoom: shownRoom)
        for view in [badge(in: cell), ListingViewController.connectingSpinner(in: cell)]
        where view.frame.minX != x {
            view.frame.origin.x = x
        }
        if let eject = shownEjectButton(in: cell) {
            let ejectX = ejectX(cellWidth: cell.bounds.width, chevronRoom: shownRoom)
            if eject.frame.minX != ejectX {
                eject.frame.origin.x = ejectX
            }
        }
        fitName(in: cell, chevronRoom: chevronRoom)
    }

    /// Adds `button`, an eject button, to the name cell `cell`, centered in its height, laid out
    /// with frames and autoresizing as the cell's other views are.
    static func addEjectButton(_ button: HoverButton, to cell: ListingNameCellView) {
        let side = HoverButton.side
        button.frame = NSRect(
            x: ejectX(cellWidth: cell.bounds.width, chevronRoom: nil),
            y: (cell.bounds.height - side) / 2, width: side, height: side)
        button.autoresizingMask = [.minXMargin, .minYMargin, .maxYMargin]
        cell.addEjectButton(button)
    }

    /// The name cell's eject button when it shows one, else nil.
    static func shownEjectButton(in cell: NSTableCellView) -> HoverButton? {
        guard let button = (cell as? ListingNameCellView)?.ejectButton, !button.isHidden else {
            return nil
        }
        return button
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

    /// Adds `dots`, tag dots, to the name cell `cell`, centered in its height, laid out with
    /// frames and autoresizing as the cell's other views are. `fitName` places them across.
    static func addTagDots(_ dots: RowTagDotsView, to cell: ListingNameCellView) {
        dots.frame.origin.y = (cell.bounds.height - RowTagDotsView.size(count: 1).height) / 2
        dots.autoresizingMask = [.minYMargin, .maxYMargin]
        cell.addTagDots(dots)
    }

    /// The name cell's tag dots when it shows them, else nil.
    static func shownTagDots(in cell: NSTableCellView) -> RowTagDotsView? {
        guard let dots = (cell as? ListingNameCellView)?.tagDots, !dots.isHidden else {
            return nil
        }
        return dots
    }

    /// Puts the name cell's tag dots, when it shows them, after the name or as far right as
    /// `tagDotsEnd` lets them, and sets the name's width from the cell's: up to the dots when
    /// they show, else up to the eject button when it shows, else up to the badge when it
    /// shows, else up to the chevron, which takes `chevronRoom`, when it shows, else up to the
    /// trailing padding. Set outright, since autoresizing clamps a width at zero in a column
    /// narrower than the name and the badge, and widening the column doesn't give that back.
    static func fitName(in cell: NSTableCellView, chevronRoom: Double) {
        guard let textField = cell.textField else {
            preconditionFailure("the name cell has no text field: \(cell.subviews)")
        }
        (cell as? ListingNameCellView)?.fittedChevronRoom = chevronRoom
        let shownRoom = shownChevronRoom(cell, chevronRoom: chevronRoom)
        let badge =
            !badge(in: cell).isHidden || !ListingViewController.connectingSpinner(in: cell).isHidden
        let eject = shownEjectButton(in: cell) != nil
        var dotsX: Double?
        if let dots = shownTagDots(in: cell) {
            let end = tagDotsEnd(
                cellWidth: cell.bounds.width,
                columnChevronRoom: chevron(in: cell) == nil ? nil : chevronRoom,
                chevronRoom: shownRoom, badge: badge, eject: eject)
            let x = tagDotsX(
                nameX: textField.frame.minX, nameWidth: nameWidth(textField.stringValue),
                width: dots.frame.width, end: end)
            if dots.frame.minX != x {
                dots.frame.origin.x = x
            }
            dotsX = x
        }
        let end = nameEnd(
            cellWidth: cell.bounds.width, chevronRoom: shownRoom, badge: badge, eject: eject,
            tagDotsX: dotsX)
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

    /// A cell of `column` in `rows`, laid out with frames and autoresizing, which costs less per
    /// row than constraints. With `chevronImage` it is a column of column view's name cell,
    /// whose chevron takes `chevronRoom`.
    static func makeCell(
        for column: SortColumn, rows: Rows, chevronImage: NSImage?, chevronRoom: Double
    ) -> NSTableCellView {
        let height = rows.height
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
        } else if column == .name {
            cell = ListingNameCellView(frame: frame)
        } else {
            cell = NSTableCellView(frame: frame)
        }
        cell.identifier = column.identifier
        var textX = 2.0
        if column == .name {
            let side = rows.iconSize
            let imageView = NSImageView(
                frame: NSRect(x: 2, y: (height - side) / 2, width: side, height: side))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.minYMargin, .maxYMargin]
            // The icon repeats the Kind column, so VoiceOver reads the name alone.
            imageView.setAccessibilityElement(false)
            cell.addSubview(imageView)
            cell.imageView = imageView
            textX = rows.nameX
        }
        let textField = NSTextField(labelWithString: "")
        // Muted beside the name, as Finder draws them. AppKit draws both near white on an
        // emphasized selection.
        if column != .name {
            textField.textColor = .secondaryLabelColor
        }
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
