import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// `/r` holds a folder `docs`, a folder `other` and a file `a.txt`; `/r/docs` holds a folder
/// `sub` and a file `x.txt`; `/r/docs/sub` holds two FLAC files.
private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [folder("docs"), folder("other"), file("a.txt")],
    "/r/docs": [folder("sub"), file("x.txt")],
    "/r/docs/sub": [file("one.flac"), file("two.flac")],
    "/r/other": [file("o.txt")],
]

/// A pane at `/r` in column mode, shown by a column view that is never put in a window, `width`
/// points wide, with its first column loaded. The pane's changes reach the view as
/// `PaneViewController` passes them on.
@MainActor
private struct Fixture {
    let pane: Pane
    let controller: ColumnViewController
    let lister: StubLister

    init(
        width: Double = 800, iconCache: TypeIconCache = TypeIconCache { _ in NSImage() },
        folders: [String: [DirectoryEntry]] = tree
    ) async {
        lister = StubLister(folders)
        pane = Pane(
            location: Location(path: "/r"),
            service: ListingService(lister: lister, rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
            viewMode: .column)
        let controller = ColumnViewController(pane: pane, iconCache: iconCache, formatter: .init())
        controller.startMonitor = { _ in }
        self.controller = controller
        pane.onChange = { [weak controller] in controller?.paneDidChange() }
        controller.view.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        controller.view.layoutSubtreeIfNeeded()
        await settle { trail.focused.pane.state.isLoaded }
    }

    var trail: ColumnTrail {
        guard let trail = pane.columnTrail else {
            preconditionFailure("the pane isn't in column mode")
        }
        return trail
    }

    var tables: [ListingTableView] { controller.columnControllers.map(\.tableView) }

    /// Selects `name` alone in the column at `index`, as a click or a key does, and waits for the
    /// column it opens to load.
    func select(_ name: String, inColumn index: Int) async {
        let pane = trail.columns[index].pane
        pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }
    }

    /// Opens `/r/docs/sub` in three columns, the first one focused.
    func openThreeColumns() async {
        await select("docs", inColumn: 0)
        await select("sub", inColumn: 1)
    }
}

@MainActor @Test func aThreeColumnTrailShowsThreeSingleColumnTablesWithItsRowsAndSelection()
    async throws
{
    let fixture = await Fixture()

    await fixture.openThreeColumns()

    #expect(fixture.tables.count == 3)
    for (column, table) in zip(fixture.trail.columns, fixture.tables) {
        let listing = try #require(column.pane.state.listing)
        #expect(table.numberOfRows == listing.count)
        #expect(table.selectedRowIndexes == column.pane.selection.rows(in: listing))
        #expect(table.tableColumns.count == 1)
        #expect(table.headerView == nil)
    }
    #expect(rowNames(fixture.tables[2]) == ["one.flac", "two.flac"])
    // a.txt, docs, other.
    #expect(fixture.tables[0].selectedRowIndexes == [1])
    #expect(fixture.tables[1].selectedRowIndexes == [0])
    #expect(fixture.tables[2].selectedRowIndexes == [])
}

@MainActor @Test func selectingAFolderAddsItsColumnAndDropsTheColumnsRightOfIt() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let first = fixture.tables[0]

    await fixture.select("other", inColumn: 0)

    #expect(fixture.tables.count == 2)
    #expect(fixture.tables[0] === first)
    #expect(rowNames(fixture.tables[1]) == ["o.txt"])
    #expect(fixture.controller.columnControllers.allSatisfy { $0.view.superview != nil })

    await fixture.select("a.txt", inColumn: 0)

    #expect(fixture.tables.count == 1)
    #expect(fixture.tables[0] === first)
}

@MainActor @Test func theFocusedColumnIsScrolledIntoViewWhenArrowsMovePastTheEdge() async throws {
    // Room for two columns.
    let fixture = await Fixture(width: ColumnViewController.columnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let scrollView = try #require(fixture.controller.view as? NSScrollView)
    let third = fixture.controller.columnControllers[2].view
    #expect(!scrollView.documentVisibleRect.contains(third.frame))

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    #expect(fixture.trail.focusedIndex == 2)
    #expect(scrollView.documentVisibleRect.contains(third.frame))

    fixture.trail.moveLeft()
    fixture.trail.moveLeft()

    let first = fixture.controller.columnControllers[0].view
    #expect(scrollView.documentVisibleRect.contains(first.frame))
}

@MainActor @Test func aCutEntryDrawsDimmedInAColumnOpenedAfterTheCut() async throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let clipboard = CutState(clipboard: PasteboardFileClipboard(pasteboard: pasteboard))
    let fixture = await Fixture()
    fixture.controller.clipboard = clipboard
    clipboard.cut([URL(fileURLWithPath: "/r/docs/x.txt", isDirectory: false)])

    await fixture.select("docs", inColumn: 0)

    let column = try #require(fixture.controller.columnControllers.last)
    let listing = try #require(column.listing)
    let table = column.tableView
    let alphas = try (0..<listing.count).map { row in
        let cell = column.tableView(table, viewFor: table.tableColumns[0], row: row)
        return (listing[row].name, try #require(cell).alphaValue)
    }
    #expect(alphas.map(\.0) == ["sub", "x.txt"])
    #expect(alphas.map(\.1) == [1, ListingViewController.cutAlpha])
}

@MainActor @Test func everyColumnTakesDropsIntoItsFolder() async throws {
    let fixture = await Fixture()
    let queue = FileOperationQueue(
        prompts: .unexpected
    ) { _ in }
    let mounts = MountTable(read: { [] })
    fixture.controller.fileOperations = queue
    fixture.controller.mountTable = mounts

    await fixture.openThreeColumns()

    #expect(fixture.controller.columnControllers.count == 3)
    for column in fixture.controller.columnControllers {
        #expect(column.fileOperations === queue)
        #expect(column.mountTable === mounts)
    }
}

@MainActor @Test func twoFlacFilesInAColumnShareOneIcon() async throws {
    let maker = IconMaker()
    let fixture = await Fixture(iconCache: TypeIconCache(makeIcon: maker.icon(for:)))
    await fixture.openThreeColumns()

    let controller = fixture.controller.columnControllers[2]
    let table = controller.tableView
    let icons = try (0..<2).map { row in
        let view = controller.tableView(table, viewFor: table.tableColumns[0], row: row)
        return try #require((view as? NSTableCellView)?.imageView?.image)
    }
    #expect(icons[0] === icons[1])
    #expect(maker.calls[.init(filenameExtension: "flac")!] == 1)
}

@MainActor @Test func eachColumnTellsItsPaneHowManyRowsFit() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    fixture.controller.view.layoutSubtreeIfNeeded()

    for column in fixture.trail.columns {
        #expect(column.pane.visibleRowCount > 5)
    }
}

@MainActor @Test func eachColumnStartsAMonitorForItsOwnPaneOnce() async throws {
    let pane = Pane(
        location: Location(path: "/r"), service: ListingService(lister: StubLister(tree)),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    var started: [Pane] = []
    let controller = ColumnViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init())
    controller.startMonitor = { started.append($0) }
    pane.onChange = { [weak controller] in controller?.paneDidChange() }
    let trail = try #require(pane.columnTrail)
    await settle { trail.focused.pane.state.isLoaded }

    trail.focused.pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }

    #expect(started.count == 2)
    #expect(started.map(\.location.path) == ["/r", "/r/docs"])
    #expect(zip(started, trail.columns).allSatisfy { $0 === $1.pane })
}

/// A column shows names only, so the parts of the row label the list reads from its other
/// columns come from the entry.
@MainActor @Test func aColumnRowsLabelReadsItsNameKindSizeAndDate() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let table = fixture.tables[1]
    fixture.controller.view.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()

    let rowView = try #require(table.rowView(atRow: 1, makeIfNecessary: false))
    let label = try #require(rowView.accessibilityLabel())

    #expect(label.hasPrefix("x.txt, "))
    #expect(label.contains(", 1 byte, modified "))
}

@MainActor @Test func makingAColumnsTableFirstResponderFocusesItsColumn() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled],
        backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView?.addSubview(fixture.controller.view)

    #expect(window.makeFirstResponder(fixture.tables[2]))

    #expect(fixture.trail.focusedIndex == 2)
    #expect(fixture.pane.location == Location(path: "/r/docs/sub"))
}

/// The views and children of the shown columns, and nothing else but the preview: a column, its
/// separator and its spinner each.
@MainActor
private func expectOnlyShownColumns(in controller: ColumnViewController) {
    let shown = controller.columnControllers
    #expect(controller.children.count == shown.count)
    #expect(zip(controller.children, shown).allSatisfy { $0 === $1 })
    // The preview view stays once made, shown or hidden.
    let subviews = controller.columnsView.subviews.filter { !($0 is ColumnPreviewView) }
    #expect(subviews.count == shown.count * 3)
    #expect(subviews.filter { $0 is NSProgressIndicator }.count == shown.count)
    #expect(shown.allSatisfy { column in subviews.contains { $0 === column.view } })
    #expect(subviews.filter { $0 is NSBox }.count == shown.count)
}

/// A truncated column's view leaves the column view, and its controller, table and pane go.
@MainActor @Test func droppedColumnsLeaveTheViewAndAreFreed() async throws {
    let fixture = await Fixture()
    await fixture.select("docs", inColumn: 0)
    weak let docsController = fixture.controller.columnControllers[1]
    weak let docsTable = fixture.controller.columnControllers[1].tableView
    weak let docsPane = fixture.trail.columns[1].pane
    expectOnlyShownColumns(in: fixture.controller)

    await fixture.select("other", inColumn: 0)
    weak let otherController = fixture.controller.columnControllers[1]
    weak let otherPane = fixture.trail.columns[1].pane
    #expect(fixture.trail.columns.map(\.pane.location.path) == ["/r", "/r/other"])
    expectOnlyShownColumns(in: fixture.controller)

    await fixture.select("a.txt", inColumn: 0)
    #expect(fixture.trail.columns.count == 1)
    expectOnlyShownColumns(in: fixture.controller)

    await settle {
        docsController == nil && docsTable == nil && docsPane == nil && otherController == nil
            && otherPane == nil
    }
    #expect(docsController == nil && docsTable == nil && docsPane == nil)
    #expect(otherController == nil && otherPane == nil)
}

/// `/r/docs/sub` open in three columns, where `/r` and `/r/docs` listed at once and
/// `/r/docs/sub` stays in flight until the test releases it, so only the third column is
/// loading. The column view's spinners wait on `clock`.
@MainActor
private struct LoadingThirdColumn {
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    let clock = ManualClock()
    let pane: Pane
    let controller: ColumnViewController
    let trail: ColumnTrail

    init() async throws {
        lister.release("/r")
        lister.release("/r/docs")
        pane = Pane(
            location: Location(path: "/r"),
            service: ListingService(lister: lister, clock: clock, rootVolumeName: { "Test Disk" }),
            systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
            viewMode: .column)
        let controller = ColumnViewController(
            pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
            clock: clock)
        controller.startMonitor = { _ in }
        pane.onChange = { [weak controller] in controller?.paneDidChange() }
        controller.view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        self.controller = controller
        let trail = try #require(pane.columnTrail)
        self.trail = trail
        await settle { trail.focused.pane.state.isLoaded }
        trail.columns[0].pane.select(Selection([ExactName("docs")], cursor: ExactName("docs")))
        await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
        trail.columns[1].pane.select(Selection([ExactName("sub")], cursor: ExactName("sub")))
    }

    func spinners() throws -> [NSProgressIndicator] {
        try (0..<trail.columns.count).map { try #require(controller.spinner(forColumnAt: $0)) }
    }
}

@MainActor @Test func eachColumnShowsItsOwnSpinnerOnceItsLoadPassesTheDelay() async throws {
    let fixture = try await LoadingThirdColumn()
    #expect(fixture.trail.columns.count == 3)
    let spinners = try fixture.spinners()
    #expect(spinners.allSatisfy { $0.isHidden })

    // Real time passing doesn't show a spinner; only the injected clock does.
    try await Task.sleep(for: .milliseconds(300))
    #expect(spinners.allSatisfy { $0.isHidden })

    fixture.clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !spinners[2].isHidden }
    #expect(spinners[0].isHidden)
    #expect(spinners[1].isHidden)
    #expect(fixture.controller.columnControllers[2].view.frame.contains(spinners[2].frame))

    fixture.lister.release("/r/docs/sub")
    await settle { fixture.trail.columns[2].pane.state.isLoaded }
    #expect(spinners.allSatisfy { $0.isHidden })
}

/// A shown spinner sits in the browser's view, but VoiceOver's browser holds only the columns.
@MainActor @Test func aShownColumnSpinnerIsNotOneOfTheBrowsersChildren() async throws {
    let fixture = try await LoadingThirdColumn()
    let spinners = try fixture.spinners()
    fixture.clock.advance(by: LoadTimeouts.spinnerDelay)
    await settle { !spinners[2].isHidden }

    let children = try #require(
        fixture.controller.columnsView.accessibilityChildren() as? [NSView])
    let columns = fixture.controller.columnControllers.map(\.view)
    #expect(children.count == columns.count)
    #expect(zip(children, columns).allSatisfy { $0 === $1 })

    fixture.lister.release("/r/docs/sub")
    await settle { fixture.trail.columns[2].pane.state.isLoaded }
}

@MainActor @Test func oneSelectedFileShowsItsPreviewRightOfTheLastColumn() async throws {
    let maker = IconMaker()
    let iconCache = TypeIconCache(makeIcon: maker.icon(for:))
    let fixture = await Fixture(iconCache: iconCache)
    await fixture.select("docs", inColumn: 0)

    await fixture.select("x.txt", inColumn: 1)
    fixture.controller.view.layoutSubtreeIfNeeded()

    let preview = try #require(fixture.trail.preview)
    let view = try #require(fixture.controller.previewView)
    #expect(!view.isHidden)
    #expect(view.superview === fixture.controller.columnsView)
    let last = try #require(fixture.controller.columnControllers.last).view.frame
    #expect(view.frame.minX == last.maxX + 1)
    #expect(view.frame.size == NSSize(width: ColumnViewController.columnWidth, height: last.height))
    #expect(fixture.controller.columnsView.frame.width >= view.frame.maxX)
    #expect(view.iconView.image === iconCache.icon(for: preview.kind.type))
    #expect(view.iconView.frame.size == NSSize(width: 128, height: 128))
    #expect(view.nameField.stringValue == "x.txt")
    #expect(view.summaryField.stringValue == "\(preview.kind.text) – 1 byte")
    #expect(view.sizeField.stringValue == "1 byte")
    #expect(view.modifiedField.stringValue == EntryCellFormatter().date(testDate))
    #expect(!view.acceptsFirstResponder)
}

@MainActor @Test func aFolderOrNoSelectionHidesThePreviewAndTheNextFileReusesIt() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    #expect(!view.isHidden)
    #expect(view.nameField.stringValue == "a.txt")

    await fixture.select("docs", inColumn: 0)
    #expect(view.isHidden)

    await fixture.select("x.txt", inColumn: 1)
    #expect(fixture.controller.previewView === view)
    #expect(!view.isHidden)
    #expect(view.nameField.stringValue == "x.txt")

    fixture.trail.columns[1].pane.select(Selection())
    #expect(view.isHidden)
}

@MainActor @Test func aPatchedFileUpdatesItsPreview() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    let column = fixture.trail.columns[0].pane

    column.apply(.patches([.update(file("a.txt", size: 2_000_000))]), at: column.location)

    await settle { view.sizeField.stringValue == "2 MB" }
    #expect(view.summaryField.stringValue.hasSuffix(" – 2 MB"))

    column.apply(.patches([.remove(name: "a.txt")]), at: column.location)

    await settle { view.isHidden }
}

/// → into a column whose first row is a file shows that file's preview past the right edge; it
/// is scrolled into view with the focused column.
@MainActor @Test func thePreviewIsScrolledIntoViewWithTheFocusedColumn() async throws {
    // Room for two columns.
    let fixture = await Fixture(width: ColumnViewController.columnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let scrollView = try #require(fixture.controller.view as? NSScrollView)

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    #expect(fixture.trail.focusedIndex == 2)
    #expect(fixture.trail.preview?.location == Location(path: "/r/docs/sub/one.flac"))
    let view = try #require(fixture.controller.previewView)
    let focused = fixture.controller.columnControllers[2].view.frame
    #expect(scrollView.documentVisibleRect.contains(focused))
    #expect(scrollView.documentVisibleRect.contains(view.frame))

    // → on a file does nothing.
    fixture.trail.moveRight()
    #expect(fixture.trail.focusedIndex == 2)
}

/// `/r` holding a file with a long name that has no spaces to wrap at.
private let longName = String(repeating: "a", count: 120) + ".txt"

/// A file in `/r` that has no size, as a socket has none.
private let socket = DirectoryEntry(
    name: "socket", type: .other, size: nil, modified: testDate, isHidden: false,
    isDataless: false)

@MainActor @Test func everyFieldStaysInsideThePreviewWidth() async throws {
    var folders = tree
    folders["/r"] = [file(longName)]
    let fixture = await Fixture(folders: folders)
    await fixture.select(longName, inColumn: 0)
    let view = try #require(fixture.controller.previewView)

    view.summaryField.stringValue =
        "Portable Document Format (PDF) – 12.3 MB" + String(repeating: " and more", count: 6)
    fixture.controller.view.layoutSubtreeIfNeeded()

    let fields = try #require(view.accessibilityChildren() as? [NSTextField])
    #expect(fields.count == 7)
    // Laid out, and the name wrapped onto more than one line.
    #expect(view.summaryField.frame.width > 100)
    #expect(view.nameField.frame.height > 2 * view.summaryField.frame.height)
    for field in fields {
        let frame = field.convert(field.bounds, to: view)
        #expect(frame.minX >= 0, "\(field.stringValue)")
        #expect(frame.maxX <= view.bounds.width, "\(field.stringValue)")
    }
}

@MainActor @Test func aPreviewTallerThanTheColumnScrollsVertically() async throws {
    var folders = tree
    folders["/r"] = [file(longName)]
    let fixture = await Fixture(folders: folders)
    await fixture.select(longName, inColumn: 0)
    let view = try #require(fixture.controller.previewView)

    fixture.controller.view.frame.size.height = 150
    fixture.controller.view.layoutSubtreeIfNeeded()

    let scrollView = view.scrollView
    let document = try #require(scrollView.documentView)
    #expect(scrollView.hasVerticalScroller)
    #expect(!scrollView.hasHorizontalScroller)
    #expect(document.frame.height > scrollView.contentSize.height)
    let bottom = view.modifiedField.convert(view.modifiedField.bounds, to: document)
    #expect(document.bounds.contains(bottom))
}

/// As Finder shows a socket: its kind, and no Size row.
@MainActor @Test func aFileWithoutASizeShowsItsKindAndNoSizeRow() async throws {
    var folders = tree
    folders["/r"] = [file("a.txt"), socket]
    let fixture = await Fixture(folders: folders)

    await fixture.select("socket", inColumn: 0)

    let view = try #require(fixture.controller.previewView)
    let kind = try #require(fixture.trail.preview?.kind.text)
    #expect(view.summaryField.stringValue == kind)
    #expect(view.sizeField.isHidden)
    let fields = try #require(view.accessibilityChildren() as? [NSTextField])
    #expect(!fields.contains { $0 === view.sizeField })

    await fixture.select("a.txt", inColumn: 0)

    #expect(!view.sizeField.isHidden)
    let shown = try #require(view.accessibilityChildren() as? [NSTextField])
    #expect(shown.contains { $0 === view.sizeField })
}

private func entry(_ name: String, _ type: DirectoryEntry.FileType) -> DirectoryEntry {
    DirectoryEntry(
        name: name, type: type, size: nil, modified: testDate, isHidden: false, isDataless: false)
}

/// The folder chevron in a name cell, shown or not.
@MainActor
private func chevron(_ cell: NSTableCellView) throws -> NSImageView {
    try #require(
        cell.subviews.first { $0.identifier == ListingViewController.folderChevronIdentifier }
            as? NSImageView)
}

@MainActor
private func nameCell(_ table: NSTableView, row: Int) throws -> NSTableCellView {
    try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)
}

private let longFolder = "a-very-long-folder-name-that-cannot-fit-in-a-column-at-all"

private let chevronTree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/r": [
        entry("App.app", .package), file("a.txt"), folder("docs"),
        entry("link", .symbolicLink), entry(longFolder, .directory),
    ],
    "/r/docs": [],
]

@MainActor @Test func onlyFolderRowsShowTheChevron() async throws {
    let fixture = await Fixture(folders: chevronTree)
    let table = fixture.tables[0]

    for (row, name) in rowNames(table).enumerated() {
        let isFolder = name == "docs" || name == longFolder
        #expect(try !chevron(nameCell(table, row: row)).isHidden == isFolder, "\(name)")
    }
}

@MainActor @Test func theChevronIsOneSharedSymbolImage() async throws {
    let iconCache = TypeIconCache { _ in NSImage() }
    let fixture = await Fixture(iconCache: iconCache, folders: chevronTree)
    let table = fixture.tables[0]

    let images = try (0..<table.numberOfRows).map { try chevron(nameCell(table, row: $0)).image }
    #expect(images.allSatisfy { $0 === iconCache.folderChevron })
    #expect(iconCache.folderChevron.isTemplate)
}

@MainActor @Test func aNameEndsBeforeTheChevron() async throws {
    let fixture = await Fixture(folders: chevronTree)
    let table = fixture.tables[0]
    let names = rowNames(table)
    let cell = try nameCell(table, row: try #require(names.firstIndex(of: longFolder)))
    let mark = try chevron(cell)
    let text = try #require(cell.textField)

    #expect(text.frame.maxX <= mark.frame.minX)
    #expect(mark.frame.maxX <= cell.bounds.width)
    // A file's name takes the room back.
    let file = try nameCell(table, row: try #require(names.firstIndex(of: "a.txt")))
    #expect(try #require(file.textField).frame.width > text.frame.width)
}

@MainActor @Test func theChevronFollowsTheRowsSelectionStyle() async throws {
    let fixture = await Fixture(folders: chevronTree)
    let cell = try nameCell(fixture.tables[0], row: 0)
    let mark = try chevron(cell)

    cell.backgroundStyle = .emphasized
    #expect(mark.contentTintColor == .alternateSelectedControlTextColor)
    cell.backgroundStyle = .normal
    #expect(mark.contentTintColor == .secondaryLabelColor)
}

@MainActor @Test func aSelectedRowInAFocusedColumnTurnsItsChevronWhite() async throws {
    let fixture = await Fixture(folders: chevronTree)
    let table = fixture.tables[0]
    let row = try #require(rowNames(table).firstIndex(of: "docs"))
    let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: true))
    let cell = try #require(rowView.view(atColumn: 0) as? NSTableCellView)

    rowView.isSelected = true
    rowView.isEmphasized = true
    draw(rowView)
    #expect(cell.backgroundStyle == .emphasized)
    #expect(try chevron(cell).contentTintColor == .alternateSelectedControlTextColor)

    rowView.isEmphasized = false
    draw(rowView)
    #expect(try chevron(cell).contentTintColor == .secondaryLabelColor)
}

@MainActor @Test func aNotDownloadedFolderShowsItsBadgeLeftOfTheChevron() async throws {
    let cloud = DirectoryEntry(
        name: "cloud", type: .directory, size: nil, modified: testDate, isHidden: false,
        isDataless: true)
    let fixture = await Fixture(folders: ["/": [folder("r")], "/r": [cloud], "/r/cloud": []])
    let cell = try nameCell(fixture.tables[0], row: 0)
    let mark = try chevron(cell)
    let badge = try #require(
        cell.subviews.first { $0.identifier == ListingViewController.notDownloadedBadgeIdentifier })
    let text = try #require(cell.textField)

    #expect(!badge.isHidden && !mark.isHidden)
    #expect(badge.frame.maxX <= mark.frame.minX)
    #expect(text.frame.maxX <= badge.frame.minX)
}

@MainActor @Test func aCellRefilledBetweenAFolderAndAFileTakesTheNewRowsChevronAndBadge()
    async throws
{
    func dataless(_ name: String, _ type: DirectoryEntry.FileType) -> DirectoryEntry {
        DirectoryEntry(
            name: name, type: type, size: nil, modified: testDate, isHidden: false,
            isDataless: true)
    }
    let fixture = await Fixture(folders: [
        "/": [folder("r")], "/r": [dataless("a", .directory), file("b")],
    ])
    let table = fixture.tables[0]
    let before = try (0..<2).map { try nameCell(table, row: $0) }
    #expect(try !chevron(before[0]).isHidden && chevron(before[1]).isHidden)

    fixture.lister.set("/r", to: [dataless("a", .regular), dataless("b", .directory)])
    fixture.pane.reload()
    await settle { fixture.trail.columns[0].pane.state.listing?[0].type == .regular }
    fixture.controller.view.layoutSubtreeIfNeeded()

    let after = try (0..<2).map { try nameCell(table, row: $0) }
    #expect(after[0] === before[0] && after[1] === before[1])
    #expect(try chevron(after[0]).isHidden && !chevron(after[1]).isHidden)
    let badges = after.map { cell in
        cell.subviews.first { $0.identifier == ListingViewController.notDownloadedBadgeIdentifier }
    }
    let file = try #require(badges[0])
    let folder = try #require(badges[1])
    // The file's badge is back at the trailing edge, the folder's left of its chevron.
    #expect(!file.isHidden && !folder.isHidden)
    #expect(file.frame.maxX == after[0].bounds.width - 2)
    #expect(try folder.frame.maxX <= chevron(after[1]).frame.minX)
    #expect(try #require(after[0].textField).frame.maxX <= file.frame.minX)
    #expect(try #require(after[1].textField).frame.maxX <= folder.frame.minX)
}

@MainActor @Test func aListsNameCellsHaveNoChevron() async throws {
    let list = await controller(showing: [folder("c"), file("a.txt")])
    let table = list.tableView

    for row in 0..<2 {
        let cell = try #require(
            list.tableView(table, viewFor: table.tableColumns[0], row: row) as? NSTableCellView)
        #expect(!(cell is ColumnNameCellView))
        #expect(
            !cell.subviews.contains {
                $0.identifier == ListingViewController.folderChevronIdentifier
            }
        )
    }
}

@MainActor @Test func aNameInAColumnTooNarrowForItsChevronGetsNoWidth() async throws {
    let fixture = await Fixture(folders: chevronTree)
    let table = fixture.tables[0]
    let row = try #require(rowNames(table).firstIndex(of: "docs"))
    let cell = try nameCell(table, row: row)
    let nameColumn = table.tableColumns[0]
    nameColumn.minWidth = 1
    nameColumn.width = 1
    fixture.controller.view.layoutSubtreeIfNeeded()

    #expect(try #require(cell.textField).frame.width == 0)
}

/// Draws `view` into a bitmap, as AppKit does before it shows a row, which is when a row view
/// gives its cells their background style.
@MainActor
private func draw(_ view: NSView) {
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        preconditionFailure("no bitmap for \(view.bounds)")
    }
    view.cacheDisplay(in: view.bounds, to: bitmap)
}
