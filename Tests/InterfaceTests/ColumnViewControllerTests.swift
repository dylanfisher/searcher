import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// `/Volumes/r`, a volume, so its trail starts there, holds a folder `docs`, a folder `other` and a
/// file `a.txt`; `/Volumes/r/docs` holds a folder `sub` and a file `x.txt`; `/Volumes/r/docs/sub`
/// holds two FLAC files.
private let tree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/Volumes/r": [folder("docs"), folder("other"), file("a.txt")],
    "/Volumes/r/docs": [folder("sub"), file("x.txt")],
    "/Volumes/r/docs/sub": [file("one.flac"), file("two.flac")],
    "/Volumes/r/other": [file("o.txt")],
]

/// A pane at `/Volumes/r` in column mode, shown by a column view that is never put in a window,
/// `width` points wide, with its first column loaded. Its service makes thumbnails with
/// `thumbnails`, or none. The pane's changes reach the view as `PaneViewController` passes them
/// on.
@MainActor
private struct Fixture {
    let pane: Pane
    let controller: ColumnViewController
    let lister: StubLister
    /// Where the trail waits out `ColumnTrail.previewHold`.
    let holdClock = ManualClock()

    init(
        width: Double = 800, iconCache: TypeIconCache = TypeIconCache { _ in NSImage() },
        folders: [String: [DirectoryEntry]] = tree, settings: Settings = untouchedSettings(),
        thumbnails: ThumbnailService? = nil
    ) async {
        lister = StubLister(folders)
        pane = Pane(
            location: Location(path: "/Volumes/r"),
            service: ListingService(
                lister: lister, rootVolumeName: { "Test Disk" }, thumbnails: thumbnails),
            systemActions: StubSystemActions(), settings: settings, isFocused: true,
            viewMode: .column)
        pane.previewHoldClock = holdClock
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
    /// column it opens to load and, unless `waitingForTheRead` is false, for a file's preview
    /// to show once its info is read.
    func select(_ name: String, inColumn index: Int, waitingForTheRead: Bool = true) async {
        let pane = trail.columns[index].pane
        pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        await settle {
            trail.columns.allSatisfy { $0.pane.state.isLoaded }
                && (!waitingForTheRead || trail.shownPreview == trail.preview)
        }
    }

    /// Opens `/Volumes/r/docs/sub` in three columns, the first one focused.
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

/// The folder menu acts on the column's folder, so a right-click below a column's rows clears
/// the folder selected there, which New Folder and Paste would otherwise act in, and its column
/// closes. A right-click on a row keeps the rows menu.
@MainActor @Test func aRightClickBelowAColumnsRowsClearsItsSelection() async throws {
    let fixture = await Fixture()
    await fixture.select("docs", inColumn: 0)
    let first = fixture.controller.columnControllers[0]
    first.tableView.registry = try AppCommands.registry()

    let menu = first.contextMenu(forRow: -1)

    #expect(menu.items.contains { $0.representedObject as? CommandID == FileCommands.newFolder.id })
    #expect(fixture.trail.columns[0].pane.selection.isEmpty)
    #expect(fixture.tables.count == 1)
}

@MainActor @Test func theColumnsBounceSidewaysEvenWhenTheyFit() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 4)
    await fixture.openThreeColumns()
    let scrollView = try #require(fixture.controller.view as? NSScrollView)

    #expect(scrollView.documentView.map { $0.frame.width <= scrollView.contentSize.width } == true)
    #expect(scrollView.horizontalScrollElasticity == .allowed)
}

@MainActor @Test func aVerticalBounceStaysInsideTheColumn() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 4)
    await fixture.openThreeColumns()
    let scrollView = try #require(fixture.controller.view as? NSScrollView)

    #expect(scrollView.verticalScrollElasticity == .none)
}

@MainActor @Test func theFocusedColumnIsScrolledIntoViewWhenArrowsMovePastTheEdge() async throws {
    // Room for two columns.
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
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

/// What the view asked its scroll to do: the left edge it moved to and whether it animated.
@MainActor
private final class ScrollLog {
    var requests: [(x: Double, animated: Bool)] = []
}

extension Fixture {
    /// Records each scroll the view asks for and makes it at once, so a test reads the result
    /// without waiting on an animation.
    func logScrolls() -> ScrollLog {
        let log = ScrollLog()
        controller.animateScroll = { clip, x, animated in
            log.requests.append((x, animated))
            ColumnViewController.moveClip(clip, toX: x, animated: false)
        }
        return log
    }
}

@MainActor @Test func theScrollToTheFocusedColumnIsAnimatedAndReachesItsTarget() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let log = fixture.logScrolls()
    fixture.controller.reduceMotion = { false }
    let scrollView = try #require(fixture.controller.view as? NSScrollView)
    let third = fixture.controller.columnControllers[2].view

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    let last = try #require(log.requests.last)
    #expect(last.animated)
    #expect(scrollView.documentVisibleRect.contains(third.frame))
    #expect(abs(last.x - scrollView.contentView.bounds.origin.x) < 0.5)
}

/// Stands in for the clip view's animator, which AppKit runs on display refresh and so never
/// runs with the display asleep. Records what each animated move asks for and ends the latest
/// one when the test says.
@MainActor
final class ClipAnimation {
    private(set) var starts: [(origin: NSPoint, duration: TimeInterval)] = []

    func start(_ clip: NSClipView, to origin: NSPoint, over duration: TimeInterval) {
        starts.append((origin, duration))
    }

    /// Ends the animation at the target a later move retargeted it to.
    func finish(_ clip: NSClipView) {
        if let last = starts.last { clip.setBoundsOrigin(last.origin) }
    }
}

@MainActor @Test func anAnimatedScrollEndsAtTheLatestTarget() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.controller.reduceMotion = { false }
    let animation = ClipAnimation()
    fixture.controller.animateScroll = { clip, x, animated in
        ColumnViewController.moveClip(clip, toX: x, animated: animated, animate: animation.start)
    }
    let clip = try #require((fixture.controller.view as? NSScrollView)?.contentView)
    let second = fixture.controller.columnControllers[1].view
    let third = fixture.controller.columnControllers[2].view

    // Two columns right, then one back before the first animation ends: the second and third
    // columns are the ones in view. Had the last move not been the animation's target, the
    // origin would end at an earlier one.
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    fixture.trail.moveLeft()
    #expect(animation.starts.count == 3)
    #expect(animation.starts.allSatisfy { $0.duration == ColumnViewController.scrollDuration })
    #expect(ColumnViewController.scrollDuration == 0.25)
    animation.finish(clip)

    let visible = clip.documentVisibleRect
    #expect(visible.contains(second.frame) && visible.contains(third.frame))
    #expect(clip.bounds.origin.x < third.frame.minX - second.frame.width / 2)
}

@MainActor @Test func aMoveFromAFractionalOriginEndsOnTheTarget() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let clip = try #require((fixture.controller.view as? NSScrollView)?.contentView)

    // Where an animation in flight leaves the origin: between device pixels.
    clip.setBoundsOrigin(NSPoint(x: 13.3, y: clip.bounds.origin.y))
    ColumnViewController.moveClip(clip, toX: 0, animated: false)
    #expect(clip.bounds.origin.x == 0)

    clip.setBoundsOrigin(NSPoint(x: 13.3, y: clip.bounds.origin.y))
    ColumnViewController.moveClip(clip, toX: 100, animated: false)
    #expect(clip.bounds.origin.x == 100)
}

@MainActor @Test func aJumpSetsTheOriginAtOnceAndStartsNoAnimation() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let clip = try #require((fixture.controller.view as? NSScrollView)?.contentView)
    let animation = ClipAnimation()

    ColumnViewController.moveClip(clip, toX: 200, animated: true, animate: animation.start)
    #expect(animation.starts.count == 1)
    ColumnViewController.moveClip(clip, toX: 0, animated: false, animate: animation.start)

    // Setting the origin directly is what ends an animation running in AppKit (0046).
    #expect(animation.starts.count == 1)
    #expect(clip.bounds.origin.x == 0)
}

@MainActor @Test func aFocusMoveDuringAGripDragJumps() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let log = fixture.logScrolls()
    fixture.controller.reduceMotion = { false }
    let grip = try #require(fixture.controller.grip(forColumnAt: 0))

    grip.beginResize(false)
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    grip.endResize()

    #expect(!log.requests.isEmpty)
    #expect(log.requests.allSatisfy { !$0.animated })
}

@MainActor @Test func theScrollEndsOnTheDeviceGrid() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let clip = try #require((fixture.controller.view as? NSScrollView)?.contentView)
    let scale = clip.window?.backingScaleFactor ?? NSScreen.screens.first?.backingScaleFactor ?? 2

    ColumnViewController.moveClip(clip, toX: 100.3, animated: false)

    let device = clip.bounds.origin.x * scale
    #expect(abs(device - device.rounded()) < 0.001)
}

@MainActor @Test func reduceMotionJumpsToTheFocusedColumn() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let log = fixture.logScrolls()
    fixture.controller.reduceMotion = { true }

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    #expect(!log.requests.isEmpty)
    #expect(log.requests.allSatisfy { !$0.animated })
}

@MainActor @Test func theFirstShowOfAColumnViewDoesNotAnimate() async throws {
    let log = ScrollLog()
    let lister = StubLister(tree)
    let pane = Pane(
        location: Location(path: "/Volumes/r/docs/sub"),
        service: ListingService(lister: lister, rootVolumeName: { "Test Disk" }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    let controller = ColumnViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init())
    controller.startMonitor = { _ in }
    controller.reduceMotion = { false }
    controller.animateScroll = { clip, x, animated in
        log.requests.append((x, animated))
        ColumnViewController.moveClip(clip, toX: x, animated: false)
    }
    pane.onChange = { [weak controller] in controller?.paneDidChange() }
    controller.view.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
    controller.paneDidChange()
    await settle { pane.columnTrail?.focused.pane.state.isLoaded ?? false }

    #expect(!log.requests.isEmpty)
    #expect(log.requests.first?.animated == false)
}

/// A trail built at a folder below its volume's root ends at the right edge with that folder's
/// column, the columns above it to its left, with no animation; so does one shown before the
/// view had its width (0103-column-trail-from-the-root.md).
@MainActor @Test func aNewTrailShowsItsFolderAtTheRightEdgeWithTheFoldersAboveToItsLeft()
    async throws
{
    let log = ScrollLog()
    let pane = Pane(
        location: Location(path: "/Volumes/r/docs/sub"),
        service: ListingService(lister: StubLister(tree), rootVolumeName: { "Test Disk" }),
        systemActions: StubSystemActions(), settings: untouchedSettings(), isFocused: true,
        viewMode: .column)
    let controller = ColumnViewController(
        pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init())
    controller.startMonitor = { _ in }
    controller.reduceMotion = { false }
    controller.animateScroll = { clip, x, animated in
        log.requests.append((x, animated))
        ColumnViewController.moveClip(clip, toX: x, animated: false)
    }
    pane.onChange = { [weak controller] in controller?.paneDidChange() }
    controller.paneDidChange()

    controller.view.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
    controller.view.layoutSubtreeIfNeeded()
    let trail = try #require(pane.columnTrail)
    await settle { trail.columns.allSatisfy { $0.pane.state.isLoaded } }

    try #require(controller.columnControllers.count == 3)
    let scrollView = try #require(controller.view as? NSScrollView)
    let focused = controller.columnControllers[2].view.frame
    #expect(trail.focusedIndex == 2)
    #expect(scrollView.documentVisibleRect.maxX == focused.maxX)
    #expect(log.requests.allSatisfy { !$0.animated })
}

@MainActor @Test func aNewTrailJumpsToItsFocus() async throws {
    var folders = tree
    folders["/Volumes/s"] = [file("s.txt")]
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20, folders: folders)
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    let log = fixture.logScrolls()
    fixture.controller.reduceMotion = { false }

    // A Go to folder on another volume keeps no column.
    fixture.pane.navigate(to: Location(path: "/Volumes/s"))
    await settle { fixture.trail.focused.pane.state.isLoaded }

    #expect(!log.requests.isEmpty)
    #expect(log.requests.allSatisfy { !$0.animated })
}

/// A navigation, Back or Forward to a folder outside the trail keeps the views of the columns
/// both trails show, so they don't redraw, and scrolls to the new focus as a move within the
/// trail does (0103-column-trail-from-the-root.md).
@MainActor @Test func aNewTrailFromTheSameRootKeepsTheSharedColumnsViews() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    let first = fixture.controller.columnControllers[0]
    let log = fixture.logScrolls()
    fixture.controller.reduceMotion = { false }

    fixture.pane.navigate(to: Location(path: "/Volumes/r/other"))
    await settle { fixture.trail.focused.pane.state.isLoaded }

    #expect(fixture.controller.columnControllers.count == 2)
    #expect(fixture.controller.columnControllers[0] === first)
    #expect(first.view.superview != nil)
    #expect(fixture.tables[0].selectedRowIndexes == [2])
    #expect(!log.requests.isEmpty)
    #expect(log.requests.allSatisfy { $0.animated })

    fixture.pane.goBack()

    #expect(fixture.controller.columnControllers.count == 3)
    #expect(fixture.controller.columnControllers[0] === first)
    #expect(fixture.tables[0].selectedRowIndexes == [1])
}

/// The selected row of the column at `index`, made if it isn't on screen.
@MainActor
private func selectedRowView(_ fixture: Fixture, inColumn index: Int) throws -> ListingRowView {
    let table = fixture.tables[index]
    let row = try #require(table.selectedRowIndexes.first)
    return try #require(table.rowView(atRow: row, makeIfNecessary: true) as? ListingRowView)
}

/// Whether `row`'s selection is Finder's first column's: the whole row, square.
@MainActor
private func isFullWidth(_ row: ListingRowView) -> Bool {
    row.selectionPath.bounds == row.bounds && row.selectionPath.contains(NSPoint(x: 0.5, y: 0.5))
}

/// Finder draws the selection of the trail's first column as a square band across the whole
/// column, and every other column's as the rounded band inset from its sides
/// (first-column-square.jpg, second-column-rounded.jpg).
@MainActor @Test func theFirstColumnSelectsFullWidthAndTheOthersRounded() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    fixture.controller.view.layoutSubtreeIfNeeded()

    #expect(fixture.tables.map(\.selectionShape) == [.fullWidth, .roundedBand, .roundedBand])
    let first = try selectedRowView(fixture, inColumn: 0)
    let second = try selectedRowView(fixture, inColumn: 1)
    #expect(isFullWidth(first))
    #expect(!isFullWidth(second))
    let inset = ListingRowView.selectionInset
    #expect(!second.selectionPath.contains(NSPoint(x: inset / 2, y: 12)))
    #expect(!second.selectionPath.contains(NSPoint(x: inset + 0.5, y: 0.5)))
}

/// A trail started again from another root has a new first column, which takes the full-width
/// selection; the column after it keeps the rounded one.
@MainActor @Test func aRestartedTrailsFirstColumnSelectsFullWidth() async throws {
    let fixture = await Fixture(folders: tree.merging(["/Volumes/s": [file("s.txt")]]) { $1 })
    await fixture.openThreeColumns()
    let oldFirst = fixture.tables[0]

    fixture.pane.navigate(to: Location(path: "/Volumes/s"))
    await settle { fixture.trail.focused.pane.state.isLoaded }
    fixture.pane.navigate(to: Location(path: "/Volumes/r/docs"))
    await settle { fixture.trail.columns.allSatisfy { $0.pane.state.isLoaded } }
    await fixture.select("x.txt", inColumn: 1)
    fixture.controller.view.layoutSubtreeIfNeeded()

    #expect(fixture.tables.count == 2)
    #expect(fixture.tables[0] !== oldFirst)
    #expect(fixture.tables.map(\.selectionShape) == [.fullWidth, .roundedBand])
    #expect(isFullWidth(try selectedRowView(fixture, inColumn: 0)))
    #expect(!isFullWidth(try selectedRowView(fixture, inColumn: 1)))
}

@MainActor @Test func theSelectionMovesAtOnceWhileTheScrollAnimates() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.controller.reduceMotion = { false }

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    #expect(fixture.trail.focusedIndex == 2)
    #expect(fixture.tables[2].selectedRowIndexes == [0])
}

/// Every left edge a clip view's bounds move to, as they move.
@MainActor
private final class OriginLog: NSObject {
    private(set) var xs: [Double] = []

    init(_ clip: NSClipView) {
        super.init()
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clip)
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        guard let clip = notification.object as? NSClipView else { return }
        xs.append(clip.bounds.origin.x)
    }
}

extension Fixture {
    /// The columns' clip view, scrolled right so the view's last column or preview is in view,
    /// with the trail waiting on `clock` for the keys to pause from now on.
    func scrolledToTheEnd(waitingOn clock: ManualClock) throws -> NSClipView {
        pane.columnOpenClock = clock
        let clip = try #require((controller.view as? NSScrollView)?.contentView)
        let last = try #require(
            controller.previewView.flatMap { $0.isHidden ? nil : $0 }
                ?? controller.columnControllers.last?.view)
        #expect(clip.bounds.origin.x > 0)
        #expect(clip.documentVisibleRect.contains(last.frame))
        return clip
    }

    /// Lets the keys pause, so the trail follows the selection they made, and waits for `shown`.
    func pauseKeys(on clock: ManualClock, until shown: @MainActor () -> Bool) async {
        await settle { clock.waitingSleeps == 1 }
        clock.advance(by: ColumnTrail.openDelay)
        await settle(until: shown)
    }
}

/// ↓ and ↑ between files in the last column, scrolled to its right end, leave the columns where
/// they are: the file shown stays while the keys pause and the next one shows in its place, and
/// the view doesn't scroll.
@MainActor @Test func arrowsBetweenFilesInTheLastColumnDoNotScroll() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    await settle { fixture.trail.shownPreview == fixture.trail.preview }
    let log = fixture.logScrolls()
    fixture.controller.reduceMotion = { false }
    let clock = ManualClock()
    let clip = try fixture.scrolledToTheEnd(waitingOn: clock)
    let start = clip.bounds.origin.x
    let origins = OriginLog(clip)

    fixture.trail.focused.pane.moveSelection(by: 1)

    #expect(fixture.trail.shownPreview?.location.name == "one.flac")
    #expect(clip.bounds.origin.x == start)

    await fixture.pauseKeys(on: clock) { fixture.trail.shownPreview?.location.name == "two.flac" }
    fixture.trail.focused.pane.moveSelection(by: -1)
    await fixture.pauseKeys(on: clock) { fixture.trail.shownPreview?.location.name == "one.flac" }

    #expect(origins.xs.allSatisfy { $0 == start }, "\(origins.xs)")
    #expect(log.requests.allSatisfy { $0.x == start }, "\(log.requests)")
}

/// ↓ from a folder to a file, with the folder's column at the right end, drops the column while
/// the keys pause and shows the file's preview in its place, without scrolling; ↑ back opens the
/// folder's column there again.
@MainActor @Test func arrowsBetweenAFolderAndAFileDoNotScroll() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    let log = fixture.logScrolls()
    fixture.controller.reduceMotion = { false }
    let clock = ManualClock()
    let clip = try fixture.scrolledToTheEnd(waitingOn: clock)
    let start = clip.bounds.origin.x
    let origins = OriginLog(clip)

    // `/Volumes/r/docs`: sub, x.txt.
    fixture.trail.focused.pane.moveSelection(by: 1)

    #expect(fixture.trail.columns.count == 2)
    #expect(clip.bounds.origin.x == start)

    await fixture.pauseKeys(on: clock) { fixture.trail.shownPreview?.location.name == "x.txt" }
    fixture.trail.focused.pane.moveSelection(by: -1)
    await fixture.pauseKeys(on: clock) {
        fixture.trail.columns.count == 3 && fixture.trail.columns[2].pane.state.isLoaded
    }

    #expect(origins.xs.allSatisfy { $0 == start }, "\(origins.xs)")
    #expect(log.requests.allSatisfy { $0.x == start }, "\(log.requests)")
}

/// A column narrowed at the right end leaves its room while the room shows, and a scroll to the
/// left gives the room up as it goes out of sight, so the scroller never reaches past the columns.
@MainActor @Test func theRoomANarrowedColumnLeavesGoesOnceScrolledOutOfSight() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    await settle { fixture.trail.shownPreview == fixture.trail.preview }
    let clip = try fixture.scrolledToTheEnd(waitingOn: ManualClock())
    let columnsView = fixture.controller.columnsView
    let end = clip.bounds.maxX

    drag(try #require(fixture.controller.grip(forColumnAt: 2)), by: -100)

    #expect(columnsView.frame.width == end)
    #expect(clip.bounds.maxX == end)

    // A scroll of the user's, which lays nothing out.
    clip.scroll(to: NSPoint(x: clip.bounds.origin.x - 60, y: 0))

    #expect(columnsView.frame.width == end - 60)
    clip.scroll(to: .zero)
    let previewGrip = try #require(fixture.controller.previewGrip)
    #expect(columnsView.frame.width == previewGrip.frame.maxX)
}

/// A trackpad's rubber-band past the right end moves the bounds past the columns' view; the view
/// doesn't widen to them, so the bounce comes back to the columns.
@MainActor @Test func aRubberBandPastTheRightEndDoesNotWidenTheColumns() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    await settle { fixture.trail.shownPreview == fixture.trail.preview }
    let clip = try fixture.scrolledToTheEnd(waitingOn: ManualClock())
    let columnsView = fixture.controller.columnsView
    let width = columnsView.frame.width

    clip.setBoundsOrigin(NSPoint(x: width - clip.bounds.width + 40, y: 0))
    fixture.controller.view.layoutSubtreeIfNeeded()

    #expect(columnsView.frame.width == width)
}

/// Every column, those opened later and those a new trail makes, queues its drops and renames
/// in the window's workspace, and a move to another window changes them all.
@MainActor @Test func everyColumnTakesTheWindowsWorkspace() async throws {
    let fixture = await Fixture()
    let first = UUID()
    fixture.controller.workspaceID = first
    #expect(fixture.controller.columnControllers.map(\.workspaceID) == [first])

    await fixture.openThreeColumns()
    #expect(fixture.controller.columnControllers.map(\.workspaceID) == [first, first, first])

    let second = UUID()
    fixture.controller.workspaceID = second
    #expect(fixture.controller.columnControllers.map(\.workspaceID) == [second, second, second])

    fixture.pane.navigate(to: Location(path: "/Volumes/r/other"))
    await settle { fixture.trail.focused.pane.state.isLoaded }
    #expect(fixture.controller.columnControllers.count == 2)
    #expect(fixture.controller.columnControllers.allSatisfy { $0.workspaceID == second })
}

@MainActor @Test func aCutEntryDrawsDimmedInAColumnOpenedAfterTheCut() async throws {
    let pasteboard = testPasteboard()
    defer { pasteboard.releaseGlobally() }
    let clipboard = CutState(clipboard: PasteboardFileClipboard(pasteboard: pasteboard))
    let fixture = await Fixture()
    fixture.controller.clipboard = clipboard
    clipboard.cut([URL(fileURLWithPath: "/Volumes/r/docs/x.txt", isDirectory: false)])

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
        location: Location(path: "/Volumes/r"), service: ListingService(lister: StubLister(tree)),
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
    #expect(started.map(\.location.path) == ["/Volumes/r", "/Volumes/r/docs"])
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
    let window = testWindow(size: NSSize(width: 800, height: 400))
    window.contentView?.addSubview(fixture.controller.view)

    #expect(window.makeFirstResponder(fixture.tables[2]))

    #expect(fixture.trail.focusedIndex == 2)
    #expect(fixture.pane.location == Location(path: "/Volumes/r/docs/sub"))
}

/// A press on the folder selected in a column left of the focused one closes the columns right of
/// that folder's column at mouse down, as in Finder, and leaves nothing selected in it.
@MainActor @Test func aPressOnTheSelectedFolderInAnEarlierColumnClosesTheColumnsPastItsOwn()
    async throws
{
    // Room for every column and the preview, so moving the keys to the first column scrolls
    // nothing out from under the press.
    let width = Settings.defaultColumnWidth * 5
    let fixture = await Fixture(width: width)
    await fixture.openThreeColumns()
    await fixture.select("one.flac", inColumn: 2)
    let window = testWindow(size: NSSize(width: width, height: 400))
    window.contentView?.addSubview(fixture.controller.view)
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(window.makeFirstResponder(fixture.tables[2]))
    // The first column lists a.txt, docs, other.
    let table = fixture.tables[0]
    let point = table.convert(NSPoint(x: 20, y: table.rect(ofRow: 1).midY), to: nil)
    let press = try mouseEvent(.leftMouseDown, at: point, in: window)

    table.selectOnPress(press)

    #expect(fixture.trail.focusedIndex == 0)
    #expect(fixture.trail.columns.map(\.pane.location.name) == ["r", "docs"])
    #expect(fixture.trail.columns[1].pane.selection.isEmpty)
    #expect(fixture.tables.count == 2)
    #expect(table.selectedRowIndexes == [1])
}

@MainActor @Test func aRealPressInAnotherColumnSelectsItsRowWhileTheButtonIsDown() async throws {
    let fixture = await Fixture()
    await fixture.select("docs", inColumn: 0)
    let window = testWindow(size: NSSize(width: 800, height: 400))
    window.contentView?.addSubview(fixture.controller.view)
    window.contentView?.layoutSubtreeIfNeeded()
    SecondDisplay.orderFront(window)
    defer { window.orderOut(nil) }
    #expect(fixture.trail.focusedIndex == 0)

    // The second column lists `docs`: sub, x.txt.
    let shots = try fixture.tables[1].realPress(onRow: 1)

    let held = try #require(shots.filter(\.buttonIsDown).last)
    #expect(held.hasKeys)
    #expect(held.rows == [1])
    #expect(held.drawnRows == [1])
    #expect(fixture.trail.focusedIndex == 1)
    let column = fixture.trail.columns[1].pane
    let listing = try #require(column.state.listing)
    #expect(column.selection.rows(in: listing) == [1])

    // Back in the first column: a.txt, docs, other.
    let back = try fixture.tables[0].realPress(onRow: 2)

    let backHeld = try #require(back.filter(\.buttonIsDown).last)
    #expect(backHeld.rows == [2])
    #expect(backHeld.drawnRows == [2])
    #expect(fixture.trail.focusedIndex == 0)
}

/// The views and children of the shown columns, and nothing else but the preview, its grip and
/// its separator: a column, its separator, its spinner and its grip each.
@MainActor
private func expectOnlyShownColumns(in controller: ColumnViewController) {
    let shown = controller.columnControllers
    #expect(controller.children.count == shown.count)
    #expect(zip(controller.children, shown).allSatisfy { $0 === $1 })
    // The preview view, its grip and its separator stay once made, shown or hidden.
    let subviews = controller.columnsView.subviews.filter {
        !($0 is ColumnPreviewView) && $0 !== controller.previewGrip
            && $0 !== controller.previewSeparator
    }
    #expect(subviews.count == shown.count * 4)
    #expect(subviews.filter { $0 is ColumnGripView }.count == shown.count)
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
    #expect(fixture.trail.columns.map(\.pane.location.path) == ["/Volumes/r", "/Volumes/r/other"])
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

/// `/Volumes/r/docs/sub` open in three columns, where `/Volumes/r` and `/Volumes/r/docs` listed at
/// once and `/Volumes/r/docs/sub` stays in flight until the test releases it, so only the third
/// column is loading. The column view's spinners wait on `clock`.
@MainActor
private struct LoadingThirdColumn {
    let lister = GatedLister(tree.mapValues { .batches([$0]) })
    let clock = ManualClock()
    let pane: Pane
    let controller: ColumnViewController
    let trail: ColumnTrail

    init() async throws {
        lister.release("/Volumes/r")
        lister.release("/Volumes/r/docs")
        pane = Pane(
            location: Location(path: "/Volumes/r"),
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

    fixture.lister.release("/Volumes/r/docs/sub")
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
    #expect(!children.contains { $0 is NSProgressIndicator })

    fixture.lister.release("/Volumes/r/docs/sub")
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
    #expect(
        view.frame.size == NSSize(width: Settings.defaultColumnWidth, height: last.height))
    #expect(fixture.controller.columnsView.frame.width >= view.frame.maxX)
    #expect(view.iconView.image === iconCache.icon(for: preview.kind.type))
    // Scaled up from the icon's size, square, as Finder draws a type icon.
    #expect(view.iconView.frame.width == view.iconView.frame.height)
    #expect(view.iconView.frame.width > ColumnPreview.defaultImageSide)
    #expect(view.nameField.stringValue == "x.txt")
    #expect(view.summaryField.stringValue == "\(preview.kind.text) – 1 byte")
    #expect(view.modifiedField.stringValue == EntryCellFormatter().longDate(testDate))
    #expect(!view.acceptsFirstResponder)
}

/// The preview shows the file's type icon until its thumbnail is made, then the thumbnail in the
/// same square (0102-thumbnails.md).
@MainActor @Test func thePreviewShowsTheFilesThumbnailInPlaceOfItsIconOnceMade() async throws {
    let maker = GatedThumbnailMaker()
    let typeIcon = NSImage(size: NSSize(width: 1, height: 1))
    var folders = tree
    folders["/Volumes/r"] = [file("photo.jpg")]
    let fixture = await Fixture(
        iconCache: TypeIconCache { _ in typeIcon }, folders: folders,
        thumbnails: ThumbnailService(maker: maker))
    await fixture.select("photo.jpg", inColumn: 0, waitingForTheRead: false)
    #expect(await maker.waitForCalls(1))
    // Past the hold, the file shows with its type icon.
    fixture.holdClock.advance(by: ColumnTrail.previewHold)
    await settle { fixture.trail.shownPreview == fixture.trail.preview }
    let view = try #require(fixture.controller.previewView)
    #expect(view.iconView.image === typeIcon)
    fixture.controller.view.layoutSubtreeIfNeeded()
    let square = view.iconView.frame

    maker.answer("/Volumes/r/photo.jpg", with: testThumbnail(pixels: 256))

    await settle { view.iconView.image !== typeIcon }
    #expect(view.iconView.image?.size == NSSize(width: 128, height: 128))
    fixture.controller.view.layoutSubtreeIfNeeded()
    #expect(view.iconView.frame == square)
}

/// A pane at `/Volumes/r`, holding `photo.jpg`, in a column view `height` points tall whose
/// service makes thumbnails with `maker`, with `photo.jpg` previewed and its thumbnail, `image`,
/// shown.
@MainActor
private func photoPreview(
    height: Double, maker: GatedThumbnailMaker, image: CGImage
) async throws -> (Fixture, ColumnPreviewView) {
    var folders = tree
    folders["/Volumes/r"] = [file("photo.jpg")]
    maker.answer("/Volumes/r/photo.jpg", with: image)
    let fixture = await Fixture(folders: folders, thumbnails: ThumbnailService(maker: maker))
    fixture.controller.view.frame.size.height = height
    fixture.controller.view.layoutSubtreeIfNeeded()
    await fixture.select("photo.jpg", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    await settle { view.iconView.image?.size.width == Double(image.width) / 2 }
    fixture.controller.view.layoutSubtreeIfNeeded()
    return (fixture, view)
}

/// The bottom of the preview's last field shown, in its scrolled document's flipped coordinates.
@MainActor
private func fieldsBottom(_ view: ColumnPreviewView) throws -> Double {
    let document = try #require(view.scrollView.documentView)
    let last = view.rows[view.rows.count - 1]
    return Double(last.convert(last.bounds, to: document).maxY)
}

/// Dylan: "always show preview images so that they are scaled to fill the width of the preview
/// space, unless that would push the metadata down, in which case it should be scaled down a
/// bit, like finder does". A landscape photo in a tall preview is as wide as the fields.
@MainActor @Test func aThumbnailFillsThePreviewsWidth() async throws {
    let (fixture, view) = try await photoPreview(
        height: 800, maker: GatedThumbnailMaker(), image: testThumbnail(pixels: 1024, height: 768))

    let width = Settings.defaultColumnWidth - 24
    #expect(Double(view.iconView.frame.width) == width)
    #expect(Double(view.iconView.frame.height) == (width * 0.75).rounded())
    #expect(try fieldsBottom(view) <= Double(view.scrollView.contentSize.height))
    #expect(fixture.trail.preview?.thumbnail != nil)
}

/// Dylan's screenshot of Finder's preview: the photo has no drop shadow, corners rounded a few
/// points, and spans the fields' width, its left edge on the name's and the Information titles',
/// its right on the values'. Its edges stay on the rows' at every preview width the grip sets.
/// The image asked for is unframed: Quick Look's framed one, as rows show it, has a shadow,
/// rounder corners and a transparent margin that drew the photo narrower than the rows.
@MainActor @Test func aThumbnailSpansTheRowsWithFindersCornersAndNoShadow() async throws {
    let maker = GatedThumbnailMaker()
    let (fixture, view) = try await photoPreview(
        height: 1200, maker: maker, image: testThumbnail(pixels: 1024, height: 768))
    let document = try #require(view.scrollView.documentView)
    let grip = try #require(fixture.controller.previewGrip)

    #expect(maker.calls.contains { $0.side >= ColumnPreview.imageSideStep && !$0.framed })
    #expect(view.iconView.layer?.cornerRadius == ColumnPreviewView.thumbnailCornerRadius)
    #expect(view.iconView.layer?.masksToBounds == true)
    #expect(view.iconView.shadow == nil)
    #expect(view.iconView.layer?.shadowOpacity == 0)
    for offset in [0.0, 37, 123] {
        if offset > 0 { drag(grip, by: offset) }
        fixture.controller.view.layoutSubtreeIfNeeded()
        let image = view.iconView.convert(view.iconView.bounds, to: document)
        let rows = view.rows[0].convert(view.rows[0].bounds, to: document)
        let name = view.nameField.convert(view.nameField.bounds, to: document)
        #expect(image.minX == rows.minX, "at \(view.frame.width)")
        #expect(image.maxX == rows.maxX, "at \(view.frame.width)")
        #expect(abs(name.minX - rows.minX) <= 2, "at \(view.frame.width)")
    }
}

/// A type icon is drawn by its own shape, as Finder's preview draws a file's icon: it isn't
/// clipped to the thumbnail's rounded corners.
@MainActor @Test func aTypeIconInThePreviewIsNotClipped() async throws {
    let fixture = await Fixture()
    await fixture.select("docs", inColumn: 0)
    await fixture.select("x.txt", inColumn: 1)
    let view = try #require(fixture.controller.previewView)

    #expect(view.iconView.layer?.cornerRadius == 0)
    #expect(view.iconView.shadow == nil)
}

/// A portrait photo as wide as the fields would push them below the preview's bottom: it is
/// scaled down, keeping its aspect, so the last Information row ends inside the preview.
@MainActor @Test func aTallThumbnailIsScaledDownToKeepTheFieldsInView() async throws {
    let (_, view) = try await photoPreview(
        height: 400, maker: GatedThumbnailMaker(), image: testThumbnail(pixels: 600, height: 1200))

    let image = view.iconView.frame
    #expect(image.width < Settings.defaultColumnWidth - 24)
    #expect(abs(image.height - 2 * image.width) <= 2)
    #expect(image.height > ColumnPreviewView.smallestImageSide)
    #expect(try fieldsBottom(view) <= Double(view.scrollView.contentSize.height))
    #expect(try fieldsBottom(view) >= Double(view.scrollView.contentSize.height) - 24 - 2)
}

/// The thumbnail is asked for as large as the preview can draw it, at Retina scale, rather than
/// scaled up from a small one; a wider preview asks again for the file shown, which keeps its
/// thumbnail until the larger one lands.
@MainActor @Test func thePreviewAsksForAThumbnailAsLargeAsItDraws() async throws {
    let maker = GatedThumbnailMaker()
    let small = testThumbnail(pixels: 512, height: 384)
    let (fixture, view) = try await photoPreview(height: 400, maker: maker, image: small)
    let path = "/Volumes/r/photo.jpg"
    // The preview's requests, not the row's.
    func sides() -> [Double] {
        maker.calls.filter { $0.side >= ColumnPreview.imageSideStep }.map(\.side)
    }
    // 262 points wide, or 352 tall inside the margins, rounded up to a step.
    #expect(sides() == [384])
    #expect(maker.calls.allSatisfy { $0.scale == ThumbnailService.scale })
    let before = maker.calls.count
    let large = testThumbnail(pixels: 1024, height: 768)
    maker.answer(path, with: large)
    var shown: [CGImage?] = []
    let controller = fixture.controller
    fixture.pane.onChange = {
        controller.paneDidChange()
        shown.append(fixture.trail.shownPreview?.thumbnail)
    }

    drag(try #require(fixture.controller.previewGrip), by: 300)

    #expect(await maker.waitForCalls(before + 1))
    #expect(sides() == [384, ColumnPreview.largestImageSide])
    await settle { fixture.trail.shownPreview?.thumbnail === large }
    #expect(shown.allSatisfy { $0 === small || $0 === large }, "\(shown)")
    await settle { view.iconView.image?.size.width == 512 }
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

    await settle { view.summaryField.stringValue.hasSuffix(" – 2 MB") }

    column.apply(.patches([.remove(name: "a.txt")]), at: column.location)

    await settle { view.isHidden }
}

/// → into a column whose first row is a file shows that file's preview past the right edge; it
/// is scrolled into view with the focused column.
@MainActor @Test func thePreviewIsScrolledIntoViewWithTheFocusedColumn() async throws {
    // Room for two columns.
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    let scrollView = try #require(fixture.controller.view as? NSScrollView)

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    #expect(fixture.trail.focusedIndex == 2)
    #expect(fixture.trail.preview?.location == Location(path: "/Volumes/r/docs/sub/one.flac"))
    await settle { fixture.trail.shownPreview == fixture.trail.preview }
    let view = try #require(fixture.controller.previewView)
    let focused = fixture.controller.columnControllers[2].view.frame
    #expect(scrollView.documentVisibleRect.contains(focused))
    #expect(scrollView.documentVisibleRect.contains(view.frame))

    // → on a file does nothing.
    fixture.trail.moveRight()
    #expect(fixture.trail.focusedIndex == 2)
}

/// `/Volumes/r` holding a file with a long name that has no spaces to wrap at.
private let longName = String(repeating: "a", count: 120) + ".txt"

/// A file in `/Volumes/r` that has no size, as a socket has none.
private let socket = DirectoryEntry(
    name: "socket", type: .other, size: nil, modified: testDate, isHidden: false,
    isDataless: false)

@MainActor @Test func everyFieldStaysInsideThePreviewWidth() async throws {
    var folders = tree
    folders["/Volumes/r"] = [file(longName)]
    let fixture = await Fixture(folders: folders)
    let tags = (1...12).map { "Project tag \($0)" }
    let reader = GatedItemInfoReader([
        "/Volumes/r/\(longName)": ItemInfo(created: testDate, lastOpened: testDate, tags: tags)
    ])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    await fixture.select(longName, inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    await settle { !view.tagsField.isHidden }

    view.summaryField.stringValue =
        "Portable Document Format (PDF) – 12.3 MB" + String(repeating: " and more", count: 6)
    fixture.controller.view.layoutSubtreeIfNeeded()

    let fields = try #require(view.accessibilityChildren() as? [NSTextField])
    #expect(fields.count == 11)
    // The tags wrap onto more than one line.
    #expect(view.tagsField.frame.height > 2 * view.summaryField.frame.height)
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
    folders["/Volumes/r"] = [file(longName)]
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

/// As Finder shows a socket: its kind alone under its name.
@MainActor @Test func aFileWithoutASizeShowsOnlyItsKind() async throws {
    var folders = tree
    folders["/Volumes/r"] = [file("a.txt"), socket]
    let fixture = await Fixture(folders: folders)

    await fixture.select("socket", inColumn: 0)

    let view = try #require(fixture.controller.previewView)
    let kind = try #require(fixture.trail.preview?.kind.text)
    #expect(view.summaryField.stringValue == kind)

    await fixture.select("a.txt", inColumn: 0)

    #expect(view.summaryField.stringValue.hasSuffix(" – 1 byte"))
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
    "/Volumes/r": [
        entry("App.app", .package), file("a.txt"), folder("docs"),
        entry("link", .symbolicLink), entry(longFolder, .directory),
    ],
    "/Volumes/r/docs": [],
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

/// The bounds of what `image` draws, in points from its lower left: its pixels more than half
/// opaque, drawn at 4 pixels a point in the light appearance whatever the Mac's.
@MainActor
private func inkBounds(of image: NSImage) throws -> NSRect {
    let light = try #require(NSAppearance(named: .aqua))
    let scale = 4.0
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * scale),
            pixelsHigh: Int(image.size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0))
    bitmap.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    light.performAsCurrentDrawingAppearance {
        image.draw(in: NSRect(origin: .zero, size: image.size))
    }
    NSGraphicsContext.restoreGraphicsState()
    var ink = NSRect.null
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide
        where (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            // The bitmap's rows run down from the top.
            let bottom = Double(bitmap.pixelsHigh - y - 1)
            ink = ink.union(
                NSRect(x: Double(x) / scale, y: bottom / scale, width: 1 / scale, height: 1 / scale)
            )
        }
    }
    return ink
}

/// The glyph `table`'s chevron draws in the row named `name`, measured as drawn, not by its
/// view's frame, in the row's coordinates, and the row.
@MainActor
private func drawnChevron(
    _ table: NSTableView, row name: String
) throws -> (glyph: NSRect, row: ListingRowView) {
    let row = try #require(rowNames(table).firstIndex(of: name))
    let rowView = try #require(table.rowView(atRow: row, makeIfNecessary: true) as? ListingRowView)
    let cell = try #require(rowView.view(atColumn: 0) as? NSTableCellView)
    let mark = try chevron(cell)
    // The view draws its image unscaled, centered across it.
    let image = try #require(mark.image)
    #expect(mark.imageScaling == .scaleNone && mark.imageAlignment == .alignCenter)
    let ink = try inkBounds(of: image)
    let imageMinX = mark.frame.minX + (mark.frame.width - image.size.width) / 2
    let glyph = rowView.convert(
        NSRect(x: imageMinX + ink.minX, y: mark.frame.minY, width: ink.width, height: ink.height),
        from: cell)
    return (glyph, rowView)
}

/// Finder's chevron is small and thin beside the 13-point name: its glyph about 6 points tall
/// and 3.5 wide, measured from Dylan's screenshots (chevron-finder.jpg). In a column after the
/// trail's first its right edge is 4.5 points inside the rounded selection
/// (second-column-rounded.jpg); in the first, whose selection runs the whole row, it is about
/// 15.75 points from the column's right edge (first-column-square.jpg).
@MainActor @Test func theChevronIsFindersSize() async throws {
    let iconCache = TypeIconCache { _ in NSImage() }
    let fixture = await Fixture(iconCache: iconCache)
    await fixture.openThreeColumns()
    fixture.controller.view.layoutSubtreeIfNeeded()
    #expect(iconCache.folderChevron.symbolConfiguration == TypeIconCache.folderChevronConfiguration)

    let first = try drawnChevron(fixture.tables[0], row: "docs")
    let second = try drawnChevron(fixture.tables[1], row: "sub")
    for glyph in [first.glyph, second.glyph] {
        #expect(abs(glyph.height - 6) <= 1, "\(glyph)")
        #expect(abs(glyph.width - 3.5) <= 1, "\(glyph)")
    }
    let fromFirstEdge = first.row.bounds.maxX - first.glyph.maxX
    #expect(abs(fromFirstEdge - 15.75) <= 0.5, "\(fromFirstEdge)")
    let bandMaxX = second.row.bounds.maxX - ListingRowView.selectionInset
    let insideBand = bandMaxX - second.glyph.maxX
    #expect(abs(insideBand - 4.5) <= 0.5, "\(insideBand)")
}

/// A column that stops or starts being its trail's first moves its chevron to where Finder draws
/// it for that column's selection, and its badge, its name and the width that fits a name with
/// it.
@MainActor @Test func aColumnsChevronMovesWithItsSelectionShape() async throws {
    let cloud = DirectoryEntry(
        name: "cloud", type: .directory, size: nil, modified: testDate, isHidden: false,
        isDataless: true)
    let fixture = await Fixture(folders: [
        "/": [folder("r")], "/Volumes/r": [cloud, folder(longFolder)], "/Volumes/r/cloud": [],
    ])
    fixture.controller.view.layoutSubtreeIfNeeded()
    let controller = fixture.controller.columnControllers[0]
    let table = controller.tableView
    #expect(table.selectionShape == .fullWidth)
    func inset() throws -> Double {
        let drawn = try drawnChevron(table, row: "cloud")
        return drawn.row.bounds.maxX - drawn.glyph.maxX
    }
    /// Checks that the badge, the name and the long name end just before the chevron.
    func fits() throws {
        let names = rowNames(table)
        let cell = try nameCell(table, row: try #require(names.firstIndex(of: "cloud")))
        let mark = try chevron(cell)
        let badge = try #require(
            cell.subviews.first {
                $0.identifier == ListingViewController.notDownloadedBadgeIdentifier
            })
        #expect(!badge.isHidden && !mark.isHidden)
        #expect(badge.frame.maxX <= mark.frame.minX)
        #expect(badge.frame.maxX >= mark.frame.minX - 4)
        #expect(try #require(cell.textField).frame.maxX <= badge.frame.minX)
        let longRow = try #require(names.firstIndex(of: longFolder))
        let long = try nameCell(table, row: longRow)
        let longText = try #require(long.textField)
        let longMark = try chevron(long)
        #expect(longText.frame.maxX <= longMark.frame.minX)
        #expect(longText.frame.maxX >= longMark.frame.minX - 4)
        let shown = long.convert(longText.frame, to: table)
        #expect(controller.nameFrame(atRow: longRow).maxX == shown.maxX)
    }
    let firstInset = try inset()
    try fits()
    let firstFit = controller.columnWidth(fittingNameWidth: 100)

    table.selectionShape = .roundedBand

    let laterInset = try inset()
    #expect(abs(laterInset - ListingRowView.selectionInset - 4.5) <= 0.5, "\(laterInset)")
    #expect(firstInset - laterInset == 2, "\(firstInset) \(laterInset)")
    try fits()
    #expect(controller.columnWidth(fittingNameWidth: 100) <= firstFit - 2)

    table.selectionShape = .fullWidth

    #expect(try inset() == firstInset)
    try fits()
}

@MainActor @Test func aNameEndsBeforeTheChevron() async throws {
    let fixture = await Fixture(folders: chevronTree)
    let table = fixture.tables[0]
    let names = rowNames(table)
    let cell = try nameCell(table, row: try #require(names.firstIndex(of: longFolder)))
    let mark = try chevron(cell)
    let text = try #require(cell.textField)

    #expect(text.frame.maxX <= mark.frame.minX)
    // The chevron reaches a little past the cell, never past the row's selection.
    let row = try #require(cell.superview as? ListingRowView)
    #expect(row.convert(mark.frame, from: cell).maxX <= row.selectionPath.bounds.maxX)
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
    let fixture = await Fixture(folders: [
        "/": [folder("r")], "/Volumes/r": [cloud], "/Volumes/r/cloud": [],
    ])
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
        "/": [folder("r")], "/Volumes/r": [dataless("a", .directory), file("b")],
    ])
    let table = fixture.tables[0]
    let before = try (0..<2).map { try nameCell(table, row: $0) }
    #expect(try !chevron(before[0]).isHidden && chevron(before[1]).isHidden)

    fixture.lister.set("/Volumes/r", to: [dataless("a", .regular), dataless("b", .directory)])
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
    // A list still scrolls sideways through its columns.
    let scrollView = try #require(list.view as? NSScrollView)
    #expect(!(scrollView is ColumnScrollView))
    #expect(scrollView.hasHorizontalScroller)

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

/// At every width down to the minimum, and with the table's column set wider than the column,
/// a long folder name truncates in its middle, as Finder's does, and ends before the chevron,
/// which sits at the column's visible right edge; a not-downloaded folder's badge sits between
/// them. The table is as wide as the column shows, and the column can't scroll sideways.
@MainActor @Test func aLongFoldersChevronStaysAtTheColumnsVisibleRightEdge() async throws {
    let cloud = DirectoryEntry(
        name: "cloud-" + longFolder, type: .directory, size: nil, modified: testDate,
        isHidden: false, isDataless: true)
    var folders = chevronTree
    folders["/Volumes/r", default: []].append(cloud)
    let fixture = await Fixture(folders: folders)
    let column = try #require(fixture.controller.columnControllers[0].view as? NSScrollView)
    let table = fixture.tables[0]
    let names = rowNames(table)
    var chevronGaps: Set<Double> = []

    for width in [Settings.columnWidths.lowerBound, 151, Settings.defaultColumnWidth, 600] {
        fixture.pane.setColumnWidth(width, of: fixture.trail.columns[0].pane)
        // Even a table column set wider than the column comes back to its visible width.
        table.tableColumns[0].width = 2000
        fixture.controller.view.layoutSubtreeIfNeeded()
        let visible = column.contentView.frame
        #expect(table.frame.width == column.contentView.bounds.width, "\(width)")
        column.contentView.scroll(to: NSPoint(x: 50, y: 0))
        #expect(column.contentView.bounds.minX == 0, "\(width)")

        for name in [longFolder, cloud.name] {
            let cell = try nameCell(table, row: try #require(names.firstIndex(of: name)))
            let mark = try chevron(cell)
            let text = try #require(cell.textField)
            let markFrame = column.convert(mark.frame, from: cell)
            #expect(!mark.isHidden)
            #expect(markFrame.maxX <= visible.maxX, "\(name) at \(width)")
            chevronGaps.insert(visible.maxX - markFrame.maxX)
            #expect(text.lineBreakMode == .byTruncatingMiddle)
            if width < 400 {
                #expect(
                    text.frame.width < text.intrinsicContentSize.width, "\(name) at \(width)")
            }
            if name == cloud.name {
                let badge = try #require(
                    cell.subviews.first {
                        $0.identifier == ListingViewController.notDownloadedBadgeIdentifier
                    })
                #expect(!badge.isHidden)
                #expect(text.frame.maxX <= badge.frame.minX, "\(width)")
                #expect(badge.frame.maxX <= mark.frame.minX, "\(width)")
            } else {
                #expect(text.frame.maxX <= mark.frame.minX, "\(width)")
            }
        }
    }
    // The same few points from the edge at every width, for every name.
    #expect(chevronGaps.count == 1)
    #expect(try #require(chevronGaps.first) < 16)
}

/// A sideways scroll over a column goes up its responder chain, which reaches the columns' scroll
/// view before any other scroll view, so the browser scrolls, as in Finder. AppKit scrolls a
/// scroll view only in a window on screen, so the chain stands in for the scroll itself.
@MainActor @Test func aColumnsSidewaysScrollGoesUpToTheBrowser() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let browser = try #require(fixture.controller.view as? NSScrollView)

    for controller in fixture.controller.columnControllers {
        #expect(controller.view is ColumnScrollView)
        var responder = controller.view.nextResponder
        while let next = responder, !(next is NSScrollView) {
            responder = next.nextResponder
        }
        #expect(responder === browser)
    }
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

// MARK: - The info read for the preview

/// The Information rows' titles, top to bottom, as shown.
@MainActor
private func informationTitles(_ view: ColumnPreviewView) throws -> [String] {
    let fields = try #require(view.accessibilityChildren() as? [NSTextField])
    let titles = [
        ColumnPreviewView.createdTitle, ColumnPreviewView.modifiedTitle,
        ColumnPreviewView.lastOpenedTitle, ColumnPreviewView.tagsTitle,
    ]
    return fields.map(\.stringValue).filter(titles.contains)
}

/// As Finder's preview orders them: Kind and size under the name, then Created, Modified and
/// Last opened under Information, with no Size row there, then Tags. A
/// read that lands after the hold, as one on a slow share does, moves no row whose dates fit
/// on a line.
@MainActor @Test func theReadFieldsShowInFindersOrderWithoutMovingTheFieldsAboveThem()
    async throws
{
    let fixture = await Fixture()
    let created = testDate.addingTimeInterval(-86_400)
    let opened = testDate.addingTimeInterval(3_600)
    let reader = GatedItemInfoReader([
        "/Volumes/r/a.txt": ItemInfo(created: created, lastOpened: opened, tags: ["Red", "Work"])
    ])
    fixture.pane.itemInfoReader = reader
    fixture.pane.setPreviewWidth(Settings.columnWidths.upperBound)
    await fixture.select("a.txt", inColumn: 0, waitingForTheRead: false)
    #expect(await reader.waitForCall("/Volumes/r/a.txt"))
    #expect(fixture.controller.previewView?.isHidden ?? true)
    fixture.holdClock.advance(by: ColumnTrail.previewHold)
    await settle { fixture.controller.previewView?.isHidden == false }
    let view = try #require(fixture.controller.previewView)
    fixture.controller.view.layoutSubtreeIfNeeded()

    // Once the hold ends, the rows are there with no value, and there are no tags.
    #expect(view.createdField.stringValue == "")
    #expect(view.lastOpenedField.stringValue == "")
    #expect(view.tagsField.isHidden)
    #expect(
        try informationTitles(view) == [
            ColumnPreviewView.createdTitle, ColumnPreviewView.modifiedTitle,
            ColumnPreviewView.lastOpenedTitle,
        ])
    // Each row's frame; a longer value only widens its field, leftward.
    func places() -> [NSRect] {
        view.rows.map { $0.convert($0.bounds, to: view) }
    }
    let before = places()

    reader.releaseAll()
    await settle { view.createdField.stringValue == EntryCellFormatter().longDate(created) }
    fixture.controller.view.layoutSubtreeIfNeeded()

    #expect(view.lastOpenedField.stringValue == EntryCellFormatter().longDate(opened))
    #expect(!view.tagsField.isHidden)
    #expect(view.tagsField.stringValue == "Red, Work")
    #expect(try informationTitles(view).last == ColumnPreviewView.tagsTitle)
    #expect(places() == before)
    // Below Last opened, in the view's unflipped coordinates.
    let lastOpened = view.lastOpenedField.convert(view.lastOpenedField.bounds, to: view)
    #expect(view.tagsField.convert(view.tagsField.bounds, to: view).maxY < lastOpened.minY)
}

@MainActor @Test func aFileWithNoReadShowsNoValuesAndAFailedReadShowsDashes() async throws {
    var folders = tree
    let cloud = DirectoryEntry(
        name: "cloud.txt", type: .regular, size: 9, modified: testDate, isHidden: false,
        isDataless: true)
    folders["/Volumes/r"] = [file("a.txt"), cloud]
    let fixture = await Fixture(folders: folders)
    let reader = GatedItemInfoReader([
        "/Volumes/r/a.txt": nil,
        "/Volumes/r/cloud.txt": ItemInfo(created: testDate, lastOpened: nil, tags: []),
    ])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader

    await fixture.select("cloud.txt", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    #expect(view.createdField.stringValue == "")
    #expect(view.lastOpenedField.stringValue == "")
    #expect(view.tagsField.isHidden)

    await fixture.select("a.txt", inColumn: 0)
    await settle { view.createdField.stringValue == ColumnPreviewView.noDate }
    #expect(view.lastOpenedField.stringValue == ColumnPreviewView.noDate)
    #expect(view.tagsField.isHidden)
    #expect(reader.calls.map(\.path) == ["/Volumes/r/a.txt"])
}

/// Spotlight has no last-opened date for a file it hasn't seen opened; Finder shows "--".
@MainActor @Test func aReadWithoutALastOpenedDateShowsDashes() async throws {
    let fixture = await Fixture()
    let reader = GatedItemInfoReader([
        "/Volumes/r/a.txt": ItemInfo(created: testDate, lastOpened: nil, tags: [])
    ])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader

    await fixture.select("a.txt", inColumn: 0)

    let view = try #require(fixture.controller.previewView)
    await settle { view.createdField.stringValue == EntryCellFormatter().longDate(testDate) }
    #expect(view.lastOpenedField.stringValue == ColumnPreviewView.noDate)
}

/// Dylan saw the Information rows flash at each new file: they showed empty from the selection
/// until the read landed a frame later. Now each refill of the view shows one file's name with
/// that file's own dates, from the selection to the read.
@MainActor @Test func selectingAnotherFileShowsNoEmptyRowsOnTheWay() async throws {
    let fixture = await Fixture()
    let one = ItemInfo(
        created: testDate, lastOpened: testDate.addingTimeInterval(60), tags: ["Red"])
    let two = ItemInfo(created: testDate.addingTimeInterval(120), lastOpened: nil, tags: [])
    let reader = GatedItemInfoReader([
        "/Volumes/r/docs/sub/one.flac": one, "/Volumes/r/docs/sub/two.flac": two,
    ])
    reader.release("/Volumes/r/docs/sub/one.flac")
    fixture.pane.itemInfoReader = reader
    await fixture.openThreeColumns()
    await fixture.select("one.flac", inColumn: 2)
    let view = try #require(fixture.controller.previewView)
    let formatter = EntryCellFormatter()
    #expect(view.createdField.stringValue == formatter.longDate(testDate))
    var shown: [[String]] = []
    let controller = fixture.controller
    fixture.pane.onChange = {
        controller.paneDidChange()
        shown.append([
            view.nameField.stringValue, view.createdField.stringValue,
            view.lastOpenedField.stringValue,
            view.tagsField.isHidden ? "" : view.tagsField.stringValue,
        ])
    }

    await fixture.select("two.flac", inColumn: 2, waitingForTheRead: false)
    #expect(await reader.waitForCall("/Volumes/r/docs/sub/two.flac"))
    reader.release("/Volumes/r/docs/sub/two.flac")
    await settle { view.nameField.stringValue == "two.flac" }

    let oneShown = [
        "one.flac", formatter.longDate(testDate),
        formatter.longDate(testDate.addingTimeInterval(60)), "Red",
    ]
    let twoShown = [
        "two.flac", formatter.longDate(testDate.addingTimeInterval(120)),
        ColumnPreviewView.noDate, "",
    ]
    #expect(!shown.isEmpty)
    #expect(shown.allSatisfy { $0 == oneShown || $0 == twoShown }, "\(shown)")
    #expect(shown.last == twoShown)
}

/// Dylan saw the preview flash blank between files reached by ↓: the view hid while the keys
/// paused and stayed hidden until the next file's info and thumbnail landed. Now each refill of
/// the view, from the key to the next file's thumbnail, shows one whole file: the view never
/// hides, and the name, rows and image it shows are one file's.
@MainActor @Test func arrowsBetweenFilesNeverShowABlankPreview() async throws {
    let maker = GatedThumbnailMaker()
    let sub = "/Volumes/r/docs/sub"
    maker.answer("\(sub)/one.flac", with: testThumbnail(pixels: 256))
    let typeIcon = NSImage(size: NSSize(width: 1, height: 1))
    let fixture = await Fixture(
        iconCache: TypeIconCache { _ in typeIcon }, thumbnails: ThumbnailService(maker: maker))
    let one = ItemInfo(created: testDate, lastOpened: nil, tags: [])
    let two = ItemInfo(created: testDate.addingTimeInterval(120), lastOpened: nil, tags: [])
    let reader = GatedItemInfoReader(["\(sub)/one.flac": one, "\(sub)/two.flac": two])
    reader.release("\(sub)/one.flac")
    fixture.pane.itemInfoReader = reader
    await fixture.openThreeColumns()
    await fixture.select("one.flac", inColumn: 2)
    let view = try #require(fixture.controller.previewView)
    #expect(view.iconView.image !== typeIcon)
    let clock = ManualClock()
    fixture.pane.columnOpenClock = clock
    var shown: [[String]] = []
    let controller = fixture.controller
    fixture.pane.onChange = {
        controller.paneDidChange()
        shown.append([
            view.isHidden ? "hidden" : view.nameField.stringValue, view.createdField.stringValue,
            view.iconView.image === typeIcon ? "icon" : "thumbnail",
        ])
    }

    fixture.trail.columns[2].pane.moveSelection(by: 1)
    await settle { clock.waitingSleeps == 1 }
    clock.advance(by: ColumnTrail.openDelay)
    #expect(await reader.waitForCall("\(sub)/two.flac"))
    reader.release("\(sub)/two.flac")
    #expect(await maker.waitForCalls(2))
    maker.answer("\(sub)/two.flac", with: testThumbnail(pixels: 256))
    await settle { view.nameField.stringValue == "two.flac" }

    let formatter = EntryCellFormatter()
    let oneShown = ["one.flac", formatter.longDate(testDate), "thumbnail"]
    let twoShown = ["two.flac", formatter.longDate(testDate.addingTimeInterval(120)), "thumbnail"]
    #expect(!shown.isEmpty)
    #expect(shown.allSatisfy { $0 == oneShown || $0 == twoShown }, "\(shown)")
    #expect(shown.last == twoShown)
}

/// As Finder draws its preview's Information section: each row's title at the left in
/// secondary text and its value at the right in the label color, both in the small system
/// font, with a rule under each row and none above the first.
@MainActor @Test func theInformationRowsAreLaidOutAsFindersAre() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    fixture.controller.view.layoutSubtreeIfNeeded()

    #expect(view.nameField.font == ColumnPreviewView.nameFont)
    #expect(view.summaryField.font == ColumnPreviewView.detailFont)
    #expect(view.summaryField.textColor == .secondaryLabelColor)
    // The name and the kind and size start where the row titles do, as in Finder.
    let titlesX = aligned(view.rows[0].titleField, in: view).minX
    for field in [view.nameField, view.summaryField] {
        #expect(field.alignment != .center && field.alignment != .right)
        #expect(aligned(field, in: view).minX == titlesX)
    }
    let small = NSFont.smallSystemFontSize
    var previousBottom: Double?
    for row in view.rows {
        let frame = aligned(row, in: view)
        let title = aligned(row.titleField, in: view)
        let value = aligned(row.value, in: view)
        let rule = aligned(row.rule, in: view)
        #expect(row.titleField.font?.pointSize == small)
        #expect(row.value.font?.pointSize == small)
        #expect(row.titleField.textColor == .secondaryLabelColor)
        #expect(row.value.textColor == .labelColor)
        #expect(row.value.alignment == .right)
        #expect(row.rule.boxType == .separator)
        // The row spans the fields' width: title at its left, value at its right.
        #expect(frame.width == view.bounds.width - 24)
        #expect(title.minX == frame.minX)
        #expect(value.maxX == frame.maxX)
        #expect(value.minX >= title.maxX + InformationRow.gap)
        // A one-point rule is the row's bottom edge, under its text, and the next row starts
        // there; there is none above the first.
        #expect(rule.minY == frame.minY)
        #expect(rule.height == 1)
        #expect(rule.width == frame.width)
        #expect(rule.maxY <= min(title.minY, value.minY) - ColumnPreviewView.rowPadding)
        #expect(abs(title.maxY - (frame.maxY - ColumnPreviewView.rowPadding)) < 0.01)
        if let previousBottom { #expect(abs(frame.maxY - previousBottom) < 0.01) }
        previousBottom = frame.minY
    }
}

/// `view`'s alignment rectangle, the one Auto Layout places, in `ancestor`'s coordinates.
@MainActor
private func aligned(_ view: NSView, in ancestor: NSView) -> NSRect {
    guard let superview = view.superview else { preconditionFailure("\(view) isn't shown") }
    return superview.convert(view.alignmentRect(forFrame: view.frame), to: ancestor)
}

/// A date too long for the row beside its title wraps, right-aligned, rather than losing its
/// time.
@MainActor @Test func aLongDateWrapsInsideItsRow() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    view.modifiedField.stringValue = "Wednesday, September 30, 2026 at 12:50 PM"
    fixture.controller.view.layoutSubtreeIfNeeded()

    // Modified, two lines tall beside Created's "--" on one.
    let row = view.rows[1]
    #expect(row.frame.height > view.rows[0].frame.height + 8)
    #expect(aligned(row.value, in: row).maxX == row.bounds.maxX)
    #expect(
        aligned(row.value, in: row).minX
            >= aligned(row.titleField, in: row).maxX + InformationRow.gap)
}

/// A pane at `/Volumes/s` in column view whose folders each end in a state with no rows to show:
/// `Mail` refuses with EPERM, as privacy protection does, `locked` with EACCES, `gone` with
/// ENOENT, `stalled` never answers, `empty` holds nothing, and `full` holds a file. Loads and
/// spinners wait on `clock`.
@MainActor
private struct StateColumns {
    let lister = GatedLister([
        "/Volumes/s": .batches([
            [
                folder("Mail"), folder("locked"), folder("gone"), folder("stalled"),
                folder("empty"), folder("full"),
            ]
        ]),
        "/Volumes/s/Mail": .failure(ListingError(path: "/Volumes/s/Mail", code: EPERM)),
        "/Volumes/s/locked": .failure(ListingError(path: "/Volumes/s/locked", code: EACCES)),
        "/Volumes/s/gone": .failure(ListingError(path: "/Volumes/s/gone", code: ENOENT)),
        "/Volumes/s/stalled": .blockForever,
        "/Volumes/s/empty": .batches([[]]),
        "/Volumes/s/full": .batches([[file("f.txt")]]),
    ])
    let clock = ManualClock()
    let pane: Pane
    let controller: ColumnViewController
    let trail: ColumnTrail

    init() async throws {
        lister.releaseAll()
        pane = Pane(
            location: Location(path: "/Volumes/s"),
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
    }

    /// Selects the folder `name` in the first column, as a click does, and waits until its
    /// column's load ends.
    func open(_ name: String) async {
        trail.columns[0].pane.select(Selection([ExactName(name)], cursor: ExactName(name)))
        await settle {
            trail.columns.count == 2 && column.location.name == name
                && !PaneStatusView.isInFlight(column.state)
        }
    }

    /// The second column's pane.
    var column: Pane { trail.columns[1].pane }

    /// The second column's message, if it shows one.
    var message: String? {
        controller.messageLabel(forColumnAt: 1).flatMap { $0.isHidden ? nil : $0.stringValue }
    }

    /// Whether the second column shows the access explanation.
    var showsDenied: Bool {
        controller.deniedView(forColumnAt: 1).map { !$0.isHidden } ?? false
    }
}

@MainActor @Test func aDeniedColumnShowsTheAccessExplanationInTheColumn() async throws {
    let fixture = try await StateColumns()

    await fixture.open("Mail")

    let denied = try #require(fixture.controller.deniedView(forColumnAt: 1))
    #expect(!denied.isHidden)
    #expect(denied.titleLabel.stringValue == AccessDeniedView.title(folderName: "Mail"))
    #expect(fixture.message == nil)
    fixture.controller.view.layoutSubtreeIfNeeded()
    let column = fixture.controller.columnControllers[1].view.frame
    #expect(denied.frame.minX >= column.minX && denied.frame.maxX <= column.maxX)
    #expect(abs(denied.frame.midX - column.midX) < 1)
    #expect(abs(denied.frame.midY - column.midY) < 1)
    // The button, the widest line, fits the column too.
    let settings = denied.openSettingsButton
    let button = settings.convert(settings.bounds, to: fixture.controller.columnsView)
    #expect(button.width >= settings.fittingSize.width)
    #expect(button.minX >= column.minX && button.maxX <= column.maxX)
}

@MainActor @Test func aFailedOrMissingColumnShowsTheListsErrorLine() async throws {
    let fixture = try await StateColumns()

    await fixture.open("locked")
    #expect(fixture.message == ListingError(path: "/Volumes/s/locked", code: EACCES).description)
    #expect(!fixture.showsDenied)

    await fixture.open("gone")
    #expect(fixture.message == PaneViewController.missingMessage("/Volumes/s/gone"))
    fixture.controller.view.layoutSubtreeIfNeeded()
    let label = try #require(fixture.controller.messageLabel(forColumnAt: 1))
    let column = fixture.controller.columnControllers[1].view.frame
    #expect(label.frame.minX >= column.minX && label.frame.maxX <= column.maxX)
    #expect(abs(label.frame.midY - column.midY) < 1)

    // A column that lists shows no message.
    await fixture.open("full")
    #expect(fixture.message == nil)
}

@MainActor @Test func aSlowThenOfflineColumnWithNoRowsShowsTheStatusNote() async throws {
    let fixture = try await StateColumns()
    fixture.trail.columns[0].pane.select(
        Selection([ExactName("stalled")], cursor: ExactName("stalled")))
    #expect(await fixture.lister.waitForCall("/Volumes/s/stalled"))
    #expect(fixture.message == nil)

    fixture.clock.advance(by: LoadTimeouts.slow)
    await settle { if case .slow = fixture.column.state { true } else { false } }
    let volume = try #require(fixture.column.volumeName)
    let note = PaneStatusText().note(
        for: fixture.column.state, volumeName: volume, now: Date())
    #expect(fixture.message == note)
    #expect(fixture.message == "\(volume) is slow to answer.")

    fixture.clock.advance(by: LoadTimeouts.giveUp - LoadTimeouts.slow)
    await settle { fixture.column.state.isOffline }
    #expect(fixture.message == "\(volume) is offline.")
}

/// Finder shows an empty folder's column blank.
@MainActor @Test func anEmptyFoldersColumnIsBlank() async throws {
    let fixture = try await StateColumns()

    await fixture.open("empty")

    #expect(fixture.message == nil)
    #expect(!fixture.showsDenied)
}

@MainActor @Test func aColumnWhoseFilterMatchesNothingSaysSoAsTheListDoes() async throws {
    let fixture = try await StateColumns()
    await fixture.open("full")

    fixture.column.setFilter("zz")

    await settle { fixture.column.state.listing?.count == 0 }
    #expect(fixture.message == FilterBarView.noMatchMessage("zz"))

    // The rows coming back in the same column hide the message.
    fixture.column.setFilter("")

    await settle { fixture.column.state.listing?.count == 1 }
    #expect(fixture.message == nil)
    #expect(fixture.controller.messageLabel(forColumnAt: 1)?.isHidden == true)
}

// MARK: - Column widths

/// The width of each column, left to right, as laid out.
@MainActor
private func columnWidths(_ fixture: Fixture) -> [Double] {
    fixture.controller.columnControllers.map { Double($0.view.frame.width) }
}

/// Each column starts one point, its separator, after the one left of it, and its grip is
/// centered on that separator, as tall as the column.
@MainActor
private func expectPacked(_ fixture: Fixture) throws {
    let controller = fixture.controller
    var x = 0.0
    for (index, column) in controller.columnControllers.enumerated() {
        #expect(Double(column.view.frame.minX) == x)
        let grip = try #require(controller.grip(forColumnAt: index))
        #expect(Double(grip.frame.midX) == Double(column.view.frame.maxX) + 0.5)
        #expect(grip.frame.minY == 0)
        #expect(Double(grip.frame.width) == ColumnGripView.thickness)
        #expect(grip.frame.height == column.view.frame.height)
        x = Double(column.view.frame.maxX) + 1
    }
}

/// The pointer's moves of the drags `gripDrags` makes: back and forth, by fractions of a point, as
/// a trackpad's are.
private let gripDrags: [[Double]] = [[-30.37, -60.81, -90.13], [-60.4, -20.77, 40.29]]

/// Drags the focused column's grip with the view scrolled to its right end, back and forth: the
/// view doesn't scroll, so the grip stays under the pointer and nothing left of it moves, and a
/// drag back to where it started leaves every column where it was.
@MainActor @Test func aDragAtTheRightEndKeepsTheGripUnderThePointer() async throws {
    let fixture = await Fixture(width: Settings.defaultColumnWidth * 2 + 20)
    await fixture.openThreeColumns()
    fixture.trail.moveRight()
    fixture.trail.moveRight()
    await settle { fixture.trail.shownPreview == fixture.trail.preview }
    let clip = try fixture.scrolledToTheEnd(waitingOn: ManualClock())
    let start = clip.bounds.origin.x
    let grip = try #require(fixture.controller.grip(forColumnAt: 2))
    let column = fixture.controller.columnControllers[2].view
    let left = column.frame.minX
    let gripX = grip.frame.midX

    for moves in gripDrags {
        let pressX = grip.frame.midX
        grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100))
        for move in moves {
            grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 100 + move))
            #expect(clip.bounds.origin.x == start, "\(move)")
            #expect(column.frame.minX == left)
            #expect(abs(grip.frame.midX - (pressX + move)) <= 0.5, "\(move)")
        }
        grip.mouseUp(with: gripEvent(.leftMouseUp, x: 100 + moves.last!))
    }
    // The drags left the column 50 points narrower.
    drag(grip, by: 50)

    #expect(clip.bounds.origin.x == start)
    #expect(grip.frame.midX == gripX)
}

/// A drag by fractions of a point gives whole-point widths, so every column and its rows sit on
/// the pixel grid and a column's clip view keeps its rows at its left edge, in a window on screen
/// as AppKit lays it out.
@MainActor @Test func aDragGivesWholePointWidthsAndKeepsEveryColumnsRowsAtItsLeftEdge()
    async throws
{
    var folders = tree
    folders["/Volumes/r/docs/sub"] = (0..<60).map { file("com.apple.LinkMetadata-\($0).db-wal") }
    let fixture = await Fixture(width: 1000, folders: folders)
    await fixture.openThreeColumns()
    let window = testWindow(size: NSSize(width: 700, height: 400))
    window.contentView?.wantsLayer = true
    fixture.controller.view.frame = try #require(window.contentView).bounds
    window.contentView?.addSubview(fixture.controller.view)
    SecondDisplay.orderFront(window)
    defer { window.orderOut(nil) }
    fixture.trail.moveRight()
    fixture.trail.moveRight()

    for (index, moves) in zip([1, 2, 1, 2], gripDrags + gripDrags) {
        let grip = try #require(fixture.controller.grip(forColumnAt: index))
        grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100))
        for move in moves {
            grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 100 + move))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            for controller in fixture.controller.columnControllers {
                let frame = controller.view.frame
                #expect(frame.minX == frame.minX.rounded(), "\(frame)")
                #expect(frame.width == frame.width.rounded(), "\(frame)")
                let clip = try #require((controller.view as? NSScrollView)?.contentView)
                #expect(clip.bounds.origin.x == 0, "\(move)")
                #expect(clip.frame.minX == 0, "\(move)")
                let table = controller.tableView
                table.enumerateAvailableRowViews { rowView, row in
                    let rowX = controller.view.convert(rowView.bounds, from: rowView).minX
                    #expect(rowX == 0, "row \(row) at \(move)")
                }
            }
        }
        grip.mouseUp(with: gripEvent(.leftMouseUp, x: 100 + moves.last!))
    }
}

@MainActor @Test func aDragResizesThatColumnOnlyAndLeavesTheDefault() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    let fixture = await Fixture(settings: settings)
    await fixture.openThreeColumns()
    let grip = try #require(fixture.controller.grip(forColumnAt: 1))

    drag(grip, by: 60)

    let standard = Settings.defaultColumnWidth
    let wide = standard + 60
    #expect(columnWidths(fixture) == [standard, wide, standard])
    try expectPacked(fixture)
    // As in Finder, only an Option-drag sets the width new columns get.
    #expect(settings.columnWidth == standard)

    // A column opened after the drag gets the default, and the dragged one keeps its width.
    await fixture.select("x.txt", inColumn: 1)
    await fixture.select("sub", inColumn: 1)
    #expect(columnWidths(fixture) == [standard, wide, standard])
    try expectPacked(fixture)
}

@MainActor @Test func anOptionDragResizesEveryColumnAndThePreviewAndSetsTheDefault()
    async throws
{
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let suite = folder.url.appending(path: "preferences").path
    let settings = Settings(
        defaults: try #require(UserDefaults(suiteName: suite)), log: unexpectedSettingsLog)
    let fixture = await Fixture(settings: settings)
    await fixture.openThreeColumns()
    await fixture.select("one.flac", inColumn: 2)
    let preview = try #require(fixture.controller.previewView)

    drag(try #require(fixture.controller.grip(forColumnAt: 0)), by: -45, option: true)

    let narrow = Settings.defaultColumnWidth - 45
    #expect(columnWidths(fixture) == [narrow, narrow, narrow])
    #expect(Double(preview.frame.width) == narrow)
    #expect(preview.frame.minX == fixture.controller.columnControllers[2].view.frame.maxX + 1)
    try expectPacked(fixture)
    #expect(settings.columnWidth == narrow)
    // The default outlives the app.
    let relaunched = Settings(
        defaults: try #require(UserDefaults(suiteName: suite)), log: unexpectedSettingsLog)
    #expect(relaunched.columnWidth == narrow)

    // A column opened after it gets the new default too.
    await fixture.select("other", inColumn: 0)
    #expect(columnWidths(fixture) == [narrow, narrow])
}

@MainActor @Test func anOptionClickThatDoesNotMoveChangesNothing() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    let fixture = await Fixture(settings: settings)
    await fixture.openThreeColumns()
    let grip = try #require(fixture.controller.grip(forColumnAt: 1))
    drag(grip, by: 30)

    drag(grip, by: 0, option: true)

    let standard = Settings.defaultColumnWidth
    #expect(columnWidths(fixture) == [standard, standard + 30, standard])
    #expect(settings.columnWidth == standard)
}

@MainActor @Test func dragsStopAtTheMinimumAndMaximumWidth() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let grip = try #require(fixture.controller.grip(forColumnAt: 0))

    drag(grip, by: -1000)
    #expect(columnWidths(fixture)[0] == Settings.columnWidths.lowerBound)

    drag(grip, by: 5000)
    #expect(columnWidths(fixture)[0] == Settings.columnWidths.upperBound)
    try expectPacked(fixture)
}

@MainActor @Test func draggingThePreviewsGripResizesThePreviewOnly() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let preview = try #require(fixture.controller.previewView)
    let grip = try #require(fixture.controller.previewGrip)

    drag(grip, by: 80)

    #expect(Double(preview.frame.width) == Settings.defaultColumnWidth + 80)
    #expect(columnWidths(fixture) == [Settings.defaultColumnWidth])
    #expect(Double(grip.frame.midX) == Double(preview.frame.maxX) + 0.5)
    #expect(fixture.controller.columnsView.frame.width >= grip.frame.maxX)
    // The wrapped name follows the preview's width.
    #expect(Double(preview.nameField.preferredMaxLayoutWidth) == Double(preview.frame.width) - 24)
}

/// Dylan: the preview "needs a right border to show where you can drag to resize it". It has the
/// columns' separator line at its right edge, under its grip, shown and hidden with it.
@MainActor @Test func thePreviewHasTheColumnsSeparatorAtItsRightEdge() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let preview = try #require(fixture.controller.previewView)
    let grip = try #require(fixture.controller.previewGrip)
    let line = try #require(fixture.controller.previewSeparator)

    #expect(line.superview === fixture.controller.columnsView)
    #expect(line.boxType == .separator)
    #expect(!line.isHidden)
    #expect(
        line.frame == NSRect(x: preview.frame.maxX, y: 0, width: 1, height: preview.frame.height))
    #expect(grip.frame.midX == line.frame.midX)
    drag(grip, by: 40)
    #expect(line.frame.minX == preview.frame.maxX)

    await fixture.select("docs", inColumn: 0)
    #expect(line.isHidden)
}

/// Dylan: "metadata area should have a minimum width". Narrower than `Settings.previewWidths`
/// the Information titles were cut off; the preview's grip stops there, and an Option-drag that
/// takes the columns narrower leaves the preview there.
@MainActor @Test func thePreviewStopsAtItsMinimumWidth() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let preview = try #require(fixture.controller.previewView)
    let minimum = Settings.previewWidths.lowerBound
    #expect(minimum > Settings.columnWidths.lowerBound)

    drag(try #require(fixture.controller.previewGrip), by: -1000)
    #expect(Double(preview.frame.width) == minimum)
    #expect(fixture.pane.previewWidth == minimum)

    drag(try #require(fixture.controller.grip(forColumnAt: 0)), by: -1000, option: true)
    #expect(columnWidths(fixture) == [Settings.columnWidths.lowerBound])
    #expect(Double(preview.frame.width) == minimum)
    #expect(preview.frame.minX == fixture.controller.columnControllers[0].view.frame.maxX + 1)
}

/// At its minimum width, with a date that wraps, every field of the preview is inside it, each
/// Information title is whole, and each value has room for a word of a date on a line.
/// Text in the preview that has the keys gives them back to the focused column when the preview
/// shows other text or hides, so they never stay in text that changed or is gone: a patch to the
/// shown file refills it, and the file's removal hides it.
@MainActor @Test func aRefillOrHideUnderTheKeysGivesTheFocusedColumnTheKeys() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    // On the second display: a field takes the keys through the field editor only in a window
    // that is shown.
    let window = testWindow(size: NSSize(width: 800, height: 400))
    defer { window.orderOut(nil) }
    window.contentView = fixture.controller.view
    SecondDisplay.orderFront(window)
    window.contentView?.layoutSubtreeIfNeeded()
    let view = try #require(fixture.controller.previewView)
    let table = try #require(fixture.controller.focusedController).tableView
    let column = fixture.trail.columns[0].pane
    /// Presses `field`'s text, as a click does, so the field editor takes the keys.
    func select(_ field: NSTextField) throws {
        let point = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil)
        let now = ProcessInfo.processInfo.systemUptime
        func event(_ type: NSEvent.EventType, at time: Double) throws -> NSEvent {
            try mouseEvent(type, at: point, in: window, timestamp: time)
        }
        nonisolated(unsafe) let down = try event(.leftMouseDown, at: now)
        try performRealPress(releasedBy: try event(.leftMouseUp, at: now + 0.05), selectsText: true)
        {
            field.mouseDown(with: down)
        }
    }
    try select(view.nameField)
    #expect(view.textHasKeys)

    column.apply(.patches([.update(file("a.txt", size: 2_000_000))]), at: column.location)

    await settle { view.summaryField.stringValue.hasSuffix(" – 2 MB") }
    #expect(window.firstResponder === table)

    try select(view.modifiedField)
    #expect(view.textHasKeys)
    column.apply(.patches([.remove(name: "a.txt")]), at: column.location)

    await settle { view.isHidden }
    #expect(window.firstResponder === table)
}

/// ↑ and ↓ in the preview's text hand their press to the column, and Esc, Tab and Shift-Tab
/// hand the keys back alone; Shift-↓ and → stay with the text, extending or moving its
/// selection.
@MainActor @Test func thePreviewsTextHandsTheColumnOnlyItsWayOut() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    var handed: [String?] = []
    view.returnKeys = { event in handed.append(event?.charactersIgnoringModifiers) }
    let editor = NSTextView()
    func command(_ selector: Selector) -> Bool {
        view.control(view.nameField, textView: editor, doCommandBy: selector)
    }

    #expect(command(#selector(NSResponder.moveUp(_:))))
    #expect(command(#selector(NSResponder.moveDown(_:))))
    #expect(command(#selector(NSResponder.cancelOperation(_:))))
    #expect(command(#selector(NSResponder.insertTab(_:))))
    #expect(command(#selector(NSResponder.insertBacktab(_:))))
    #expect(!command(#selector(NSResponder.moveDownAndModifySelection(_:))))
    #expect(!command(#selector(NSResponder.moveRight(_:))))

    let up = String(Character(Unicode.Scalar(UInt16(NSUpArrowFunctionKey))!))
    let down = String(Character(Unicode.Scalar(UInt16(NSDownArrowFunctionKey))!))
    #expect(handed == [up, down, nil, nil, nil])
}

@MainActor @Test func atItsMinimumWidthThePreviewsFieldsAreWhole() async throws {
    let fixture = await Fixture()
    let reader = GatedItemInfoReader([
        "/Volumes/r/a.txt": ItemInfo(created: testDate, lastOpened: testDate, tags: ["Red"])
    ])
    reader.releaseAll()
    fixture.pane.itemInfoReader = reader
    await fixture.select("a.txt", inColumn: 0)
    let view = try #require(fixture.controller.previewView)
    await settle { !view.tagsField.isHidden }
    drag(try #require(fixture.controller.previewGrip), by: -1000)
    view.modifiedField.stringValue = "Wednesday, September 30, 2026 at 12:50 PM"
    fixture.controller.view.layoutSubtreeIfNeeded()

    let fields = try #require(view.accessibilityChildren() as? [NSTextField])
    for field in fields {
        let frame = field.convert(field.bounds, to: view)
        #expect(frame.minX >= 0, "\(field.stringValue)")
        #expect(frame.maxX <= view.bounds.width, "\(field.stringValue)")
    }
    let word = ("Wednesday," as NSString).size(withAttributes: [
        .font: ColumnPreviewView.detailFont
    ]).width
    for row in view.rows {
        #expect(row.titleField.frame.width >= row.titleField.intrinsicContentSize.width)
        #expect(row.value.frame.width >= word, "\(row.titleField.stringValue)")
    }
}

@MainActor @Test func aNewColumnAndThePreviewGetTheStoredDefaultWidth() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    settings.columnWidth = 300
    let fixture = await Fixture(settings: settings)

    await fixture.openThreeColumns()
    await fixture.select("one.flac", inColumn: 2)

    #expect(columnWidths(fixture) == [300, 300, 300])
    #expect(fixture.controller.previewView.map { Double($0.frame.width) } == 300)
    try expectPacked(fixture)
}

/// A name long enough to need a column wider than the default, and one too long for any.
private let wideName = "a-folder-name-long-enough-to-need-a-wider-column"
private let endlessName = String(repeating: "w", count: 300)

private let fitTree: [String: [DirectoryEntry]] = [
    "/": [folder("r")],
    "/Volumes/r": [folder("docs"), file("a.txt")],
    "/Volumes/r/docs": [folder(wideName), folder("endless"), file("x.txt")],
    "/Volumes/r/docs/endless": [file(endlessName)],
    "/Volumes/r/docs/\(wideName)": [file("o.txt")],
]

/// The width the name field of `name`'s row in `table` has, and the width its text needs.
@MainActor
private func nameRoom(_ name: String, in table: NSTableView) throws -> (
    has: Double, needs: Double
) {
    let row = try #require(rowNames(table).firstIndex(of: name))
    let field = try #require(try nameCell(table, row: row).textField)
    return (field.frame.width, NSTextField(labelWithString: name).intrinsicContentSize.width)
}

@MainActor @Test func aDoubleClickFitsTheColumnToItsWidestName() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    let fixture = await Fixture(folders: fitTree, settings: settings)
    await fixture.select("docs", inColumn: 0)
    await fixture.select(wideName, inColumn: 1)

    doubleClick(try #require(fixture.controller.grip(forColumnAt: 1)))
    await fixture.controller.fitting?.value
    fixture.controller.view.layoutSubtreeIfNeeded()

    let widths = columnWidths(fixture)
    #expect(widths[0] == Settings.defaultColumnWidth)
    #expect(widths[1] > Settings.defaultColumnWidth)
    #expect(widths[2] == Settings.defaultColumnWidth)
    let room = try nameRoom(wideName, in: fixture.tables[1])
    #expect(room.has >= room.needs)
    #expect(room.has < room.needs + 4)
    try expectPacked(fixture)
    #expect(settings.columnWidth == Settings.defaultColumnWidth)

    // A column of short names shrinks to the minimum.
    doubleClick(try #require(fixture.controller.grip(forColumnAt: 2)))
    await fixture.controller.fitting?.value
    #expect(columnWidths(fixture)[2] == Settings.columnWidths.lowerBound)
}

@MainActor @Test func aDoubleClickStopsAtTheFitCap() async throws {
    let fixture = await Fixture(folders: fitTree)
    await fixture.select("docs", inColumn: 0)
    await fixture.select("endless", inColumn: 1)

    doubleClick(try #require(fixture.controller.grip(forColumnAt: 2)))
    await fixture.controller.fitting?.value

    #expect(columnWidths(fixture)[2] == ColumnViewController.fitWidthCap)
}

@MainActor @Test func anOptionDoubleClickFitsEveryColumnToTheWidestNameOfAll() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    let fixture = await Fixture(folders: fitTree, settings: settings)
    await fixture.select("docs", inColumn: 0)
    await fixture.select(wideName, inColumn: 1)
    await fixture.select("o.txt", inColumn: 2)
    doubleClick(try #require(fixture.controller.grip(forColumnAt: 1)))
    await fixture.controller.fitting?.value
    let fitted = columnWidths(fixture)[1]
    #expect(fitted > Settings.defaultColumnWidth)

    // Every column fits the name beside the first column's chevron, which sits further in.
    let columns = fixture.controller.columnControllers
    let firstColumnsRoom =
        columns[0].columnWidth(fittingNameWidth: 100)
        - columns[1].columnWidth(fittingNameWidth: 100)
    #expect(firstColumnsRoom > 0)
    let fittedAll = fitted + firstColumnsRoom

    doubleClick(try #require(fixture.controller.grip(forColumnAt: 0)), option: true)
    await fixture.controller.fitting?.value

    #expect(columnWidths(fixture) == [fittedAll, fittedAll, fittedAll])
    #expect(fixture.controller.previewView.map { Double($0.frame.width) } == fittedAll)
    #expect(settings.columnWidth == fittedAll)
    try expectPacked(fixture)
}

/// Double-clicks `grip`, Option held or not, and waits for the fit to land.
@MainActor
private func fit(_ grip: ColumnGripView?, option: Bool = false, in fixture: Fixture) async throws {
    doubleClick(try #require(grip), option: option)
    await fixture.controller.fitting?.value
}

/// A double-click on a column already at its fit width puts it back at the default, with no
/// width stored, so it follows the default as an unresized column does; the next one fits it
/// again. A column at any other width, even after a fit, fits.
@MainActor @Test func aDoubleClickTogglesBetweenTheFitAndTheDefault() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    settings.columnWidth = 300
    let fixture = await Fixture(folders: fitTree, settings: settings)
    await fixture.select("docs", inColumn: 0)
    await fixture.select(wideName, inColumn: 1)
    let grip = fixture.controller.grip(forColumnAt: 1)
    let docs = Location(path: "/Volumes/r/docs")
    try await fit(grip, in: fixture)
    let fitted = columnWidths(fixture)[1]
    #expect(fitted > 300)

    try await fit(grip, in: fixture)

    #expect(columnWidths(fixture) == [300, 300, 300])
    #expect(fixture.pane.columnWidths.isEmpty)
    #expect(settings.columnWidth == 300)
    try expectPacked(fixture)
    settings.columnWidth = 320
    #expect(columnWidths(fixture)[1] == 320)

    try await fit(grip, in: fixture)
    #expect(columnWidths(fixture)[1] == fitted)
    #expect(fixture.pane.columnWidths.width(of: docs) == fitted)

    // Dragged off its fit, the column fits again rather than going back.
    drag(try #require(grip), by: 10)
    try await fit(grip, in: fixture)
    #expect(columnWidths(fixture)[1] == fitted)
    #expect(settings.columnWidth == 320)
}

/// An Option-double-click with every column and the preview at the fit of them all puts them
/// all back at `Settings.defaultColumnWidth`, which becomes the width new columns get again,
/// as the Option-double-click that fitted them set the fit; the next one fits them all again.
@MainActor @Test func anOptionDoubleClickTogglesEveryColumnBetweenTheFitAndTheDefault()
    async throws
{
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    let fixture = await Fixture(folders: fitTree, settings: settings)
    await fixture.select("docs", inColumn: 0)
    await fixture.select(wideName, inColumn: 1)
    await fixture.select("o.txt", inColumn: 2)
    let grip = fixture.controller.grip(forColumnAt: 0)
    try await fit(grip, option: true, in: fixture)
    let fitted = columnWidths(fixture)[0]
    #expect(settings.columnWidth == fitted)
    #expect(fitted != Settings.defaultColumnWidth)

    try await fit(fixture.controller.previewGrip, option: true, in: fixture)

    let standard = Settings.defaultColumnWidth
    #expect(columnWidths(fixture) == [standard, standard, standard])
    #expect(fixture.controller.previewView.map { Double($0.frame.width) } == standard)
    #expect(settings.columnWidth == standard)
    #expect(fixture.pane.columnWidths.isEmpty)
    try expectPacked(fixture)

    try await fit(grip, option: true, in: fixture)
    #expect(columnWidths(fixture) == [fitted, fitted, fitted])
    #expect(settings.columnWidth == fitted)

    // One column off the fit makes the next Option-double-click fit them all again.
    drag(try #require(fixture.controller.grip(forColumnAt: 2)), by: 10)
    try await fit(grip, option: true, in: fixture)
    #expect(columnWidths(fixture) == [fitted, fitted, fitted])
    #expect(fixture.controller.previewView.map { Double($0.frame.width) } == fitted)
    #expect(fixture.pane.columnWidths.isEmpty)
}

@MainActor @Test func theFocusedColumnIsScrolledIntoViewAtAWiderWidth() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let fixture = await Fixture(width: 500, settings: storedSettings(in: folder))
    drag(
        try #require(fixture.controller.grip(forColumnAt: 0)),
        by: 400 - Settings.defaultColumnWidth,
        option: true)
    await fixture.openThreeColumns()
    let scrollView = try #require(fixture.controller.view as? NSScrollView)
    #expect(columnWidths(fixture) == [400, 400, 400])

    fixture.trail.moveRight()
    fixture.trail.moveRight()

    let third = fixture.controller.columnControllers[2].view
    #expect(scrollView.documentVisibleRect.contains(third.frame))

    await fixture.select("one.flac", inColumn: 2)
    let preview = try #require(fixture.controller.previewView)
    fixture.trail.moveLeft()
    fixture.trail.moveLeft()
    let first = fixture.controller.columnControllers[0].view
    #expect(scrollView.documentVisibleRect.contains(first.frame))
    #expect(fixture.controller.columnsView.frame.width >= preview.frame.maxX)
}

/// The view a click at `point`, in the columns' view, lands on.
@MainActor
private func hit(_ point: NSPoint, in fixture: Fixture) -> NSView? {
    let columns = fixture.controller.columnsView
    guard let superview = columns.superview else { preconditionFailure("no clip view") }
    return columns.hitTest(columns.convert(point, to: superview))
}

/// A grip runs the whole height of its separator and a few points either side of it, over the
/// edges of the columns left and right of it, as a split view's divider does; a click anywhere
/// along it goes to the grip, and one a few points further out reaches the column's rows.
@MainActor @Test func aGripTakesClicksAlongTheWholeSeparator() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let grip = try #require(fixture.controller.grip(forColumnAt: 0))
    let left = fixture.controller.columnControllers[0].view
    let right = fixture.controller.columnControllers[1].view

    for y in [left.frame.minY + 1, left.frame.midY, left.frame.maxY - 1] {
        let inLeft = NSPoint(x: grip.frame.minX + 0.5, y: y)
        let inRight = NSPoint(x: grip.frame.maxX - 0.5, y: y)
        #expect(left.frame.contains(inLeft))
        #expect(right.frame.contains(inRight))
        #expect(hit(inLeft, in: fixture) === grip)
        #expect(hit(inRight, in: fixture) === grip)
        let pastLeft = NSPoint(x: grip.frame.minX - 2, y: y)
        let pastRight = NSPoint(x: grip.frame.maxX + 2, y: y)
        #expect(hit(pastLeft, in: fixture)?.isDescendant(of: left) == true)
        #expect(hit(pastRight, in: fixture)?.isDescendant(of: right) == true)
    }
}

/// A vertical scroll over a grip goes to the scroll view of the column under the pointer: the
/// column left of the separator over the line and its left side, the column or the preview right
/// of it over its right side.
@MainActor @Test func aGripScrollsTheColumnUnderThePointer() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    await fixture.select("one.flac", inColumn: 2)
    let controller = fixture.controller
    let columns = controller.columnsView
    let preview = try #require(controller.previewView)
    func target(_ grip: ColumnGripView?, atX x: (NSRect) -> Double) throws -> NSView? {
        let grip = try #require(grip)
        let point = NSPoint(x: x(grip.frame), y: grip.frame.midY)
        return grip.scrollTarget(columns.convert(point, to: nil))
    }

    let first = controller.grip(forColumnAt: 0)
    #expect(try target(first) { $0.minX + 0.5 } === controller.columnControllers[0].view)
    #expect(try target(first) { $0.midX } === controller.columnControllers[0].view)
    #expect(try target(first) { $0.maxX - 0.5 } === controller.columnControllers[1].view)
    let last = controller.grip(forColumnAt: 2)
    #expect(try target(last) { $0.maxX - 0.5 } === preview.scrollView)
    #expect(try target(controller.previewGrip) { $0.minX + 0.5 } === preview.scrollView)
    #expect(try target(controller.previewGrip) { $0.maxX - 0.5 } == nil)
}

/// At the far right the last grip, and the preview's, fit inside the columns' view, so their
/// right halves take clicks too.
@MainActor @Test func theLastGripFitsInsideTheColumnsViewAndTakesClicks() async throws {
    let fixture = await Fixture(width: 300)
    await fixture.openThreeColumns()
    let last = try #require(fixture.controller.grip(forColumnAt: 2))

    #expect(fixture.controller.columnsView.bounds.contains(last.frame))
    #expect(hit(NSPoint(x: last.frame.maxX - 1, y: last.frame.midY), in: fixture) === last)

    await fixture.select("one.flac", inColumn: 2)
    let preview = try #require(fixture.controller.previewGrip)
    #expect(fixture.controller.columnsView.bounds.contains(preview.frame))
    #expect(
        hit(NSPoint(x: preview.frame.maxX - 1, y: preview.frame.midY), in: fixture) === preview)
}

/// An Option-drag whose own column closes before the release still resizes the columns left and
/// sets the default from the width the drag gave them.
@MainActor @Test func anOptionDragWhoseColumnClosesStillSetsTheDefault() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    let fixture = await Fixture(settings: settings)
    await fixture.openThreeColumns()
    let grip = try #require(fixture.controller.grip(forColumnAt: 2))
    grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100, option: true))
    grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 140, option: true))

    await fixture.select("x.txt", inColumn: 1)
    grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 160, option: true))
    grip.mouseUp(with: gripEvent(.leftMouseUp, x: 160, option: true))

    // The columns left keep following the drag after its own column closes.
    let wide = Settings.defaultColumnWidth + 60
    #expect(columnWidths(fixture) == [wide, wide])
    #expect(settings.columnWidth == wide)
}

/// A plain drag whose column closes before the release resizes nothing else.
@MainActor @Test func aPlainDragWhoseColumnClosesResizesNothingElse() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let grip = try #require(fixture.controller.grip(forColumnAt: 2))
    grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100))

    await fixture.select("x.txt", inColumn: 1)
    grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 160))
    grip.mouseUp(with: gripEvent(.leftMouseUp, x: 160))

    let standard = Settings.defaultColumnWidth
    #expect(columnWidths(fixture) == [standard, standard])
    try expectPacked(fixture)
}

/// A fit whose column closes before the names are measured lands on no column, and the fit is
/// over: the folder's column opened again gets the default width.
@MainActor @Test func aFitForAClosedColumnIsDropped() async throws {
    let fixture = await Fixture(folders: fitTree)
    await fixture.select("docs", inColumn: 0)
    doubleClick(try #require(fixture.controller.grip(forColumnAt: 1)))
    let fit = try #require(fixture.controller.fitting)

    await fixture.select("a.txt", inColumn: 0)
    await fit.value

    #expect(fixture.controller.fitting == nil)
    #expect(columnWidths(fixture) == [Settings.defaultColumnWidth])
    await fixture.select("docs", inColumn: 0)
    #expect(columnWidths(fixture) == [Settings.defaultColumnWidth, Settings.defaultColumnWidth])
}

/// A new fit cancels the one before it, whose result never lands.
@MainActor @Test func aNewFitCancelsTheOneBefore() async throws {
    let fixture = await Fixture(folders: fitTree)
    await fixture.select("docs", inColumn: 0)
    await fixture.select("endless", inColumn: 1)
    doubleClick(try #require(fixture.controller.grip(forColumnAt: 2)))
    let first = try #require(fixture.controller.fitting)

    doubleClick(try #require(fixture.controller.grip(forColumnAt: 1)))
    await first.value
    await fixture.controller.fitting?.value

    #expect(first.isCancelled)
    #expect(columnWidths(fixture)[2] == Settings.defaultColumnWidth)
    #expect(columnWidths(fixture)[1] > Settings.defaultColumnWidth)
}

@MainActor @Test func closedColumnsLeaveNoGripBehind() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()

    await fixture.select("a.txt", inColumn: 0)

    let shown = fixture.controller.columnControllers
    #expect(fixture.controller.grip(forColumnAt: 1) == nil)
    // The shown column's grip and the preview's.
    #expect(
        fixture.controller.columnsView.subviews.filter { $0 is ColumnGripView }.count
            == shown.count + 1)
}

// MARK: - Widths kept by the pane

/// A drag lays the columns out on each move but hands the pane its width once, at the release,
/// so a drag starts one save (0098-column-widths-per-window.md).
@MainActor @Test func aDragHandsThePaneItsWidthOnceAtTheRelease() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    var reports = 0
    fixture.pane.onTabChange = { reports += 1 }
    let grip = try #require(fixture.controller.grip(forColumnAt: 1))

    grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100))
    for x in stride(from: 110.0, through: 160, by: 10) {
        grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: x))
    }

    let standard = Settings.defaultColumnWidth
    #expect(columnWidths(fixture) == [standard, standard + 60, standard])
    #expect(reports == 0)
    #expect(fixture.pane.columnWidths.isEmpty)

    grip.mouseUp(with: gripEvent(.leftMouseUp, x: 160))

    #expect(reports == 1)
    #expect(fixture.pane.columnWidths.width(of: Location(path: "/Volumes/r/docs")) == standard + 60)
    #expect(columnWidths(fixture) == [standard, standard + 60, standard])
    try expectPacked(fixture)
}

@MainActor @Test func theColumnsAndThePreviewShowThePanesWidths() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    await fixture.select("one.flac", inColumn: 2)
    var widths = ColumnWidths()
    widths.set(300, of: Location(path: "/Volumes/r"))
    widths.set(150, of: Location(path: "/Volumes/r/docs/sub"))
    widths.setPreview(420)

    fixture.pane.showColumnWidths(widths)

    let standard = Settings.defaultColumnWidth
    #expect(columnWidths(fixture) == [300, standard, 150])
    #expect(fixture.controller.previewView.map { Double($0.frame.width) } == 420)
    try expectPacked(fixture)
}

/// An Option-drag in another pane's columns sets the default, which this pane's columns with no
/// width set follow on screen at once; a resized one keeps its width.
@MainActor @Test func anOptionDragInAnotherPaneMovesTheColumnsWithNoWidthSet() async throws {
    let folder = try TemporaryFolder("ColumnViewControllerTests")
    let settings = storedSettings(in: folder)
    let fixture = await Fixture(settings: settings)
    let other = await Fixture(settings: settings)
    await fixture.openThreeColumns()
    await other.openThreeColumns()
    drag(try #require(fixture.controller.grip(forColumnAt: 1)), by: 20)

    drag(try #require(other.controller.grip(forColumnAt: 0)), by: 55, option: true)

    let standard = Settings.defaultColumnWidth
    let wide = standard + 55
    #expect(columnWidths(other) == [wide, wide, wide])
    #expect(columnWidths(fixture) == [wide, standard + 20, wide])
    try expectPacked(fixture)
}

/// A plain drag that ends where it started hands the pane no width.
@MainActor @Test func aDragBackToItsStartSetsNoWidth() async throws {
    let fixture = await Fixture()
    await fixture.openThreeColumns()
    let grip = try #require(fixture.controller.grip(forColumnAt: 1))

    grip.mouseDown(with: gripEvent(.leftMouseDown, x: 100))
    grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 140))
    grip.mouseDragged(with: gripEvent(.leftMouseDragged, x: 100))
    grip.mouseUp(with: gripEvent(.leftMouseUp, x: 100))

    #expect(fixture.pane.columnWidths.isEmpty)
    #expect(columnWidths(fixture)[1] == Settings.defaultColumnWidth)
}

@MainActor @Test func theWidthsComeBackAfterTheListAndBack() async throws {
    let fixture = await Fixture()
    await fixture.select("a.txt", inColumn: 0)
    drag(try #require(fixture.controller.grip(forColumnAt: 0)), by: 40)
    drag(try #require(fixture.controller.previewGrip), by: 70)

    fixture.pane.setViewMode(.list)
    fixture.pane.setViewMode(.column)
    await settle { fixture.trail.focused.pane.state.isLoaded && fixture.trail.preview != nil }

    let standard = Settings.defaultColumnWidth
    #expect(columnWidths(fixture) == [standard + 40])
    #expect(fixture.controller.previewView.map { Double($0.frame.width) } == standard + 70)
}

/// A column's first row sits the shared margin below its top and, scrolled to the end, its last
/// row the margin above its bottom, where the columns' horizontal scroller shows (Dylan,
/// 2026-10-26).
@MainActor @Test func aColumnsRowsKeepTheSharedMarginFromItsTopAndBottom() async throws {
    let names = (0..<2_000).map { String(format: "e%04d", $0) }
    let fixture = await Fixture(folders: ["/": [folder("r")], "/Volumes/r": names.map { file($0) }])
    let table = try #require(fixture.tables.first)
    let column = try #require(table.enclosingScrollView)
    fixture.controller.view.layoutSubtreeIfNeeded()
    func frame(ofRow row: Int) -> NSRect { column.convert(table.rect(ofRow: row), from: table) }

    #expect(frame(ofRow: 0).minY == Margin.standard)

    fixture.trail.columns[0].pane.selectLastRow()
    #expect(column.contentView.frame.maxY - frame(ofRow: 1_999).maxY == Margin.standard)

    fixture.trail.columns[0].pane.selectFirstRow()
    #expect(frame(ofRow: 0).minY == Margin.standard)
}

@MainActor @Test func aJumpCentersTheRowInItsColumn() async throws {
    let names = (0..<2_000).map { String(format: "e%04d", $0) }
    let fixture = await Fixture(folders: ["/": [folder("r")], "/Volumes/r": names.map { file($0) }])
    let table = try #require(fixture.tables.first)
    fixture.controller.view.layoutSubtreeIfNeeded()

    fixture.trail.columns[0].pane.jump(to: "e1000")

    #expect(table.selectedRowIndexes == [1_000])
    #expect(abs(table.rect(ofRow: 1_000).midY - rowArea(of: table).midY) <= 1)
}
