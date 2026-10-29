import AppKit
import Base
import Browser
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Interface

private let frame = Rect(x: 0, y: 0, width: 900, height: 600)

/// Finds each favorite as `states` says, by path, `.folder` for any other path, as it is.
private final class StubResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var storedStates: [String: Favorite.State] = [:]

    var states: [String: Favorite.State] {
        get { lock.withLock { storedStates } }
        set { lock.withLock { storedStates = newValue } }
    }

    func resolve(_ favorite: Favorite) -> Favorite.Resolution {
        Favorite.Resolution(favorite: favorite, state: states[favorite.path] ?? .folder)
    }
}

/// A list of two open workspaces, "beta" and "Alpha", one closed saved workspace, "Gamma", and
/// an unnamed open one, which is the window's own; Finder's default favorites for the home folder
/// `/Users/u`, found by a stub; no volumes until a test mounts some; and a sidebar for that
/// window that is never shown, with the IDs, favorites and volumes it opens and the alerts it
/// shows recorded.
@MainActor
private final class Fixture {
    let list = WorkspaceList()
    let settings = Settings(
        defaults: temporarySuite(in: FileManager.default.temporaryDirectory.path), home: "/Users/u",
        log: unexpectedSettingsLog)
    let resolver = StubResolver()
    let favorites: Favorites
    var openedFavorites: [String] = []
    let mounts = StubSidebarVolumes()
    let volumes: SidebarVolumes
    var openedLocations: [Location] = []
    var alerts: [NSAlert] = []
    /// What the sidebar is told about whether a drag that ended was cancelled.
    var dragCancelled = false
    let own: Workspace
    let alpha: Workspace
    let beta: Workspace
    let gamma: WorkspaceState
    var opened: [UUID] = []
    var escapes = 0
    let sidebar: WorkspaceSidebarViewController
    let window = KeyCatchingWindow()
    /// Finder's glyphs as a stub reads them: a tiny image for each, none read yet.
    let icons = SidebarIcons { names in
        let data = NSImage(size: NSSize(width: 4, height: 4), flipped: false) { rect in
            NSColor.red.set()
            rect.fill()
            return true
        }.tiffRepresentation
        return Dictionary(
            uniqueKeysWithValues: names.compactMap { name in data.map { (name, $0) } })
    }

    init() throws {
        let service = ListingService(lister: StubLister(["/root": [file("a.txt")]])) { "Disk" }
        let make = {
            Workspace(
                tab: Tab(
                    pane: Pane(
                        location: Location(path: "/root"), service: service,
                        systemActions: StubSystemActions(), settings: untouchedSettings())))
        }
        alpha = make()
        beta = make()
        own = make()
        for workspace in [alpha, beta, own] {
            list.add(workspace)
        }
        try list.save(beta, as: "beta", frame: frame)
        try list.save(alpha, as: "Alpha", frame: frame)
        gamma = WorkspaceState(
            id: UUID(), name: "Gamma", frame: frame,
            tabs: alpha.tabs.map(\.state), selectedTab: 0, showsSidebar: false,
            history: WorkspaceHistory())
        try list.addSaved(gamma)
        let resolver = resolver
        favorites = Favorites(settings: settings) { resolver.resolve($0) }
        volumes = mounts.list()
        sidebar = WorkspaceSidebarViewController(
            workspace: own, list: list, favorites: favorites, volumes: volumes, settings: settings,
            icons: icons)
        sidebar.open = { [weak self] id in self?.opened.append(id) }
        sidebar.openFavorite = { [weak self] path in self?.openedFavorites.append(path) }
        sidebar.openLocation = { [weak self] location in self?.openedLocations.append(location) }
        sidebar.showAlert = { [weak self] alert in self?.alerts.append(alert) }
        sidebar.dragWasCancelled = { [weak self] _ in self?.dragCancelled ?? false }
        // The window is never ordered in; the sidebar takes it as shown.
        sidebar.windowIsShown = { _ in true }
        sidebar.onEscape = { [weak self] in self?.escapes += 1 }
        sidebar.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
        window.contentView?.addSubview(sidebar.view)
        sidebar.view.layoutSubtreeIfNeeded()
    }

    /// Another sidebar over the same lists and settings, as another window has.
    func makeSidebar() -> WorkspaceSidebarViewController {
        WorkspaceSidebarViewController(
            workspace: own, list: list, favorites: favorites, volumes: volumes, settings: settings,
            icons: icons)
    }

    /// Mounts `volumes` in place of those mounted, as the system reports a mount at a mount point
    /// no other test uses, and waits for the list to hold them; the rows follow it at once.
    func mount(_ volumes: [SidebarVolume]) async {
        mounts.set(volumes)
        VolumeEvents.didMount(at: "/sidebar-test-\(UUID().uuidString)")
        let shown = volumes.filter(\.isShown)
        await settle { self.volumes.volumes == shown }
    }

    /// Each volume's row's cell, top to bottom.
    var volumeCells: [WorkspaceSidebarViewController.Cell] {
        get throws { try cells(of: "volume", in: outline) }
    }

    var volumeNames: [String] {
        get throws { try volumeCells.map { $0.textField?.stringValue ?? "" } }
    }

    var outline: NSOutlineView { sidebar.outlineView }

    /// Whether the outline's delegate draws `row` as a group row.
    func isGroupRow(_ row: Int) -> Bool {
        outline.delegate?.outlineView?(outline, isGroupItem: outline.item(atRow: row) as Any)
            == true
    }

    /// Each workspace row's cell, top to bottom.
    var cells: [WorkspaceSidebarViewController.Cell] {
        get throws { try cells(of: "workspace", in: outline) }
    }

    var names: [String] {
        get throws { try cells.map { $0.textField?.stringValue ?? "" } }
    }

    /// Each favorite's row's cell, top to bottom.
    var favoriteCells: [WorkspaceSidebarViewController.Cell] {
        get throws { try cells(of: "favorite", in: outline) }
    }

    var favoriteNames: [String] {
        get throws { try favoriteCells.map { $0.textField?.stringValue ?? "" } }
    }

    /// The titles of the group rows, top to bottom.
    var groupTitles: [String] {
        (0..<outline.numberOfRows).filter(isGroupRow).map { row in
            (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                .textField?.stringValue ?? ""
        }
    }

    /// Each cell of rows of `kind` in `outline`, top to bottom.
    func cells(of kind: String, in outline: NSOutlineView) throws
        -> [WorkspaceSidebarViewController.Cell]
    {
        try (0..<outline.numberOfRows).compactMap { row in
            guard outline.level(forRow: row) > 0 else { return nil }
            let cell = try #require(
                outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                    as? WorkspaceSidebarViewController.Cell)
            return cell.identifier?.rawValue == kind ? cell : nil
        }
    }

    /// A drag's info carrying the file URLs of `paths`, from no view of the app.
    func drag(_ paths: [String]) -> StubDraggingInfo {
        let pasteboard = testPasteboard()
        pasteboard.clearContents()
        pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0, isDirectory: true) as NSURL })
        return StubDraggingInfo(pasteboard: pasteboard)
    }

    /// A drag's info carrying the favorite in `row`, as the sidebar's list writes it.
    func dragFavorite(row: Int) throws -> StubDraggingInfo {
        let pasteboard = testPasteboard()
        pasteboard.clearContents()
        let item = try #require(outline.item(atRow: row))
        let writer = try #require(
            outline.dataSource?.outlineView?(outline, pasteboardWriterForItem: item))
        pasteboard.writeObjects([writer])
        return StubDraggingInfo(pasteboard: pasteboard, mask: .move, source: outline)
    }

    /// Validates then accepts `info` dropped at `index` among the children of the row at
    /// `parentRow`, or on that row with `NSOutlineViewDropOnItemIndex`, as AppKit asks; returns
    /// what the validation answered.
    @discardableResult
    func drop(_ info: StubDraggingInfo, parentRow: Int, index: Int) -> NSDragOperation {
        let item = outline.item(atRow: parentRow)
        guard let dataSource = outline.dataSource,
            let operation = dataSource.outlineView?(
                outline, validateDrop: info, proposedItem: item, proposedChildIndex: index),
            !operation.isEmpty
        else { return [] }
        #expect(
            dataSource.outlineView?(outline, acceptDrop: info, item: item, childIndex: index)
                == true)
        return operation
    }

    /// The row showing `name`.
    func row(of name: String) throws -> Int {
        try #require(
            (0..<outline.numberOfRows).first { row in
                (outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView)?
                    .textField?.stringValue == name
            })
    }
}

@MainActor @Test func theSidebarListsSavedNamesInOrderUnderAGroupAndMarksOpenOnes() throws {
    let fixture = try Fixture()

    #expect(fixture.outline.style == .sourceList)
    #expect(fixture.groupTitles == ["Favorites", "Workspaces"])
    #expect(try fixture.names == ["Alpha", "beta", "Gamma"])
    #expect(try fixture.cells.map(\.showsOpen) == [true, true, false])
    #expect(
        try fixture.cells.map { $0.accessibilityLabel() ?? "" } == [
            "Alpha, open", "beta, open", "Gamma",
        ])
    #expect(fixture.outline.accessibilityLabel() == "Sidebar")
}

@MainActor @Test func returnOnARowOpensItsWorkspace() throws {
    let fixture = try Fixture()
    fixture.outline.selectRowIndexes([try fixture.row(of: "Gamma")], byExtendingSelection: false)

    fixture.outline.keyDown(with: try keyEvent("\r"))

    #expect(fixture.opened == [fixture.gamma.id])
    #expect(fixture.window.unhandledKeys.isEmpty)
}

@MainActor @Test func selectingARowByKeyDoesNotOpenIt() throws {
    let fixture = try Fixture()
    fixture.outline.selectRowIndexes([try fixture.row(of: "Alpha")], byExtendingSelection: false)

    fixture.outline.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))

    #expect(fixture.outline.selectedRow == (try fixture.row(of: "beta")))
    #expect(fixture.opened.isEmpty)
}

@MainActor @Test func escapeInTheSidebarHandsTheKeysBack() throws {
    let fixture = try Fixture()

    fixture.outline.keyDown(with: try keyEvent("\u{1B}"))

    #expect(fixture.escapes == 1)
    #expect(fixture.window.unhandledKeys.isEmpty)
}

/// A press on the list first ends text editing; a left one then gives the list the keys before
/// it is sent, as a click in Finder's sidebar does, and a right one leaves them. A press
/// elsewhere in the window is sent as it is.
@MainActor @Test func aPressOnTheListEndsTextEditingAndALeftOneGivesItTheKeys() throws {
    let fixture = try Fixture()
    let outline = fixture.sidebar.outlineView
    var endedEditing = 0
    outline.takeKeysFromText = { endedEditing += 1 }
    let onARow = outline.convert(
        NSPoint(x: 20, y: outline.rect(ofRow: try fixture.row(of: "Alpha")).midY), to: nil)
    var sent: [(ended: Int, listHasKeys: Bool)] = []
    func send() { sent.append((endedEditing, fixture.window.firstResponder === outline)) }

    outline.sendMouseDown(.rightMouseDown, atWindowPoint: onARow, send)
    outline.sendMouseDown(.leftMouseDown, atWindowPoint: NSPoint(x: 320, y: 20), send)
    outline.sendMouseDown(.leftMouseDown, atWindowPoint: onARow, send)

    #expect(sent.map(\.ended) == [1, 1, 2])
    #expect(sent.map(\.listHasKeys) == [false, false, true])
}

/// A hidden sidebar, as a collapsed one is, takes no press: the window sends it on as it is.
@MainActor @Test func aHiddenSidebarIsNotHit() throws {
    let fixture = try Fixture()
    let outline = fixture.sidebar.outlineView
    let onARow = outline.convert(
        NSPoint(x: 20, y: outline.rect(ofRow: try fixture.row(of: "Alpha")).midY), to: nil)
    #expect(outline.isHit(atWindowPoint: onARow))

    fixture.sidebar.view.isHidden = true

    #expect(!outline.isHit(atWindowPoint: onARow))
}

/// A clicked row opens a turn later, as it is listed then: a favorite removed in that turn
/// opens nothing.
@MainActor @Test func aClickedRowOpensATurnLaterUnlessItLeftTheList() async throws {
    let fixture = try Fixture()

    fixture.sidebar.openClicked(row: try fixture.row(of: "Documents"))
    #expect(fixture.openedFavorites.isEmpty)
    await Task {}.value
    #expect(fixture.openedFavorites == ["/Users/u/Documents"])

    fixture.sidebar.openClicked(row: try fixture.row(of: "Desktop"))
    fixture.favorites.remove("/Users/u/Desktop")
    await Task {}.value
    #expect(fixture.openedFavorites == ["/Users/u/Documents"])
}

@MainActor @Test func aRenameInTheModelUpdatesTheRow() throws {
    let fixture = try Fixture()

    try fixture.list.rename(fixture.alpha, as: "Zeta")

    #expect(try fixture.names == ["beta", "Gamma", "Zeta"])
}

@MainActor @Test func namingTheWindowsWorkspaceListsAndSelectsIt() throws {
    let fixture = try Fixture()
    #expect(fixture.outline.selectedRow == -1)

    try fixture.list.save(fixture.own, as: "Delta", frame: frame)

    #expect(try fixture.names == ["Alpha", "beta", "Delta", "Gamma"])
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "Delta")))
}

@MainActor @Test func closingAndOpeningASavedWorkspaceMovesItsMark() throws {
    let fixture = try Fixture()

    fixture.list.windowClosed(fixture.beta)

    #expect(try fixture.cells.map(\.showsOpen) == [true, false, false])

    fixture.list.delete(fixture.gamma.id)

    #expect(try fixture.names == ["Alpha", "beta"])
}

@MainActor @Test func aRenameWhileTheSidebarHasTheKeysKeepsTheSelectionAndTheKeys() throws {
    let fixture = try Fixture()
    #expect(fixture.window.makeFirstResponder(fixture.outline))
    fixture.outline.selectRowIndexes([try fixture.row(of: "beta")], byExtendingSelection: false)

    try fixture.list.rename(fixture.alpha, as: "Zeta")

    #expect(try fixture.names == ["beta", "Gamma", "Zeta"])
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "beta")))
    #expect(fixture.window.firstResponder === fixture.outline)
}

@MainActor @Test func deletingTheSelectedWorkspaceElsewhereSelectsTheWindowsOwnAndKeepsTheKeys()
    throws
{
    let fixture = try Fixture()
    try fixture.list.save(fixture.own, as: "Delta", frame: frame)
    #expect(fixture.window.makeFirstResponder(fixture.outline))
    fixture.outline.selectRowIndexes([try fixture.row(of: "Gamma")], byExtendingSelection: false)

    // As Delete Workspace in another window does.
    fixture.list.delete(fixture.gamma.id)

    #expect(try fixture.names == ["Alpha", "beta", "Delta"])
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "Delta")))
    #expect(fixture.window.firstResponder === fixture.outline)
}

// MARK: Favorites

@MainActor @Test func favoritesShowFindersDefaultsAboveTheWorkspaces() throws {
    let fixture = try Fixture()

    #expect(
        try fixture.favoriteNames == ["Applications", "Desktop", "Documents", "Downloads", "u"])
    #expect(try fixture.favoriteCells.allSatisfy { $0.imageView?.image != nil && !$0.showsOpen })
    #expect(try fixture.row(of: "u") < (try fixture.row(of: "Alpha")))
}

@MainActor @Test func returnOnAFavoriteOpensIt() throws {
    let fixture = try Fixture()
    fixture.outline.selectRowIndexes(
        [try fixture.row(of: "Documents")], byExtendingSelection: false)

    fixture.outline.keyDown(with: try keyEvent("\r"))

    #expect(fixture.openedFavorites == ["/Users/u/Documents"])
    #expect(fixture.opened.isEmpty)
}

@MainActor @Test func theArrowKeysCrossFromTheFavoritesToTheWorkspaces() throws {
    let fixture = try Fixture()
    fixture.outline.selectRowIndexes([try fixture.row(of: "u")], byExtendingSelection: false)

    fixture.outline.keyDown(
        with: try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags))

    #expect(fixture.outline.selectedRow == (try fixture.row(of: "Alpha")))
    fixture.outline.keyDown(
        with: try keyEvent(functionKey(NSUpArrowFunctionKey), modifiers: arrowFlags))
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "u")))
    #expect(fixture.openedFavorites.isEmpty && fixture.opened.isEmpty)
}

@MainActor @Test func droppingFoldersBetweenFavoritesAddsThemThereOnce() throws {
    let fixture = try Fixture()
    let favoritesRow = 0

    let operation = fixture.drop(
        fixture.drag(["/p/new", "/Users/u/Desktop"]), parentRow: favoritesRow, index: 1)

    #expect(!operation.isEmpty)
    #expect(
        try fixture.favoriteNames == [
            "Applications", "new", "Desktop", "Documents", "Downloads", "u",
        ])
    // Every one is a favorite already: nothing to drop.
    #expect(fixture.drop(fixture.drag(["/p/new"]), parentRow: favoritesRow, index: 0).isEmpty)
    // A drop on a favorite goes before it.
    fixture.drop(
        fixture.drag(["/p/on"]), parentRow: try fixture.row(of: "Downloads"),
        index: NSOutlineViewDropOnItemIndex)
    #expect(
        try fixture.favoriteNames == [
            "Applications", "new", "Desktop", "Documents", "on", "Downloads", "u",
        ])
    #expect(fixture.settings.favorites.map(\.path).contains("/p/on"))
}

@MainActor @Test func nothingDropsAmongTheWorkspaces() throws {
    let fixture = try Fixture()
    let workspacesRow = try #require(
        (0..<fixture.outline.numberOfRows).last(where: fixture.isGroupRow))

    #expect(fixture.drop(fixture.drag(["/p/new"]), parentRow: workspacesRow, index: 0).isEmpty)
    #expect(!fixture.settings.favorites.map(\.path).contains("/p/new"))
}

@MainActor @Test func draggingAFavoriteWithinTheGroupMovesIt() throws {
    let fixture = try Fixture()

    let operation = fixture.drop(
        try fixture.dragFavorite(row: try fixture.row(of: "u")), parentRow: 0, index: 0)

    #expect(operation == .move)
    #expect(
        try fixture.favoriteNames == ["u", "Applications", "Desktop", "Documents", "Downloads"])
}

@MainActor @Test func aFavoriteDraggedOutOfTheSidebarLeavesItAndOneDroppedInsideStays() throws {
    let fixture = try Fixture()
    let window = fixture.window
    let sidebarView = fixture.sidebar.view
    let inside = window.convertPoint(
        toScreen: sidebarView.convert(NSPoint(x: sidebarView.bounds.midX, y: 10), to: nil))
    // Far from any other test's sidebar, which counts as inside too.
    let outside = NSPoint(x: -50_000, y: -50_000)
    let documents = try #require(fixture.outline.item(atRow: try fixture.row(of: "Documents")))

    fixture.sidebar.beginDrag(of: [documents])
    fixture.sidebar.endDrag(at: inside, operation: [])
    #expect(try fixture.favoriteNames.contains("Documents"))

    fixture.sidebar.beginDrag(of: [documents])
    fixture.sidebar.endDrag(at: outside, operation: [])
    #expect(try fixture.favoriteNames == ["Applications", "Desktop", "Downloads", "u"])
    #expect(!fixture.settings.favorites.map(\.path).contains("/Users/u/Documents"))
}

@MainActor @Test func aCancelledDragOfAFavoriteOutOfTheSidebarLeavesIt() throws {
    let fixture = try Fixture()
    fixture.dragCancelled = true
    let documents = try #require(fixture.outline.item(atRow: try fixture.row(of: "Documents")))

    fixture.sidebar.beginDrag(of: [documents])
    fixture.sidebar.endDrag(at: NSPoint(x: -50_000, y: -50_000), operation: [])

    #expect(try fixture.favoriteNames.contains("Documents"))
}

@MainActor @Test func aFavoriteDroppedOnAnotherWindowsSidebarStays() throws {
    let fixture = try Fixture()
    let otherWindow = KeyCatchingWindow()
    otherWindow.setFrameOrigin(NSPoint(x: 40_000, y: 40_000))
    let other = fixture.makeSidebar()
    other.windowIsShown = { _ in true }
    other.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
    otherWindow.contentView?.addSubview(other.view)
    // On the other sidebar's workspace rows, outside this window.
    let onOther = otherWindow.convertPoint(
        toScreen: other.view.convert(NSPoint(x: 100, y: 250), to: nil))
    let documents = try #require(fixture.outline.item(atRow: try fixture.row(of: "Documents")))

    fixture.sidebar.beginDrag(of: [documents])
    fixture.sidebar.endDrag(at: onOther, operation: [])

    #expect(try fixture.favoriteNames.contains("Documents"))
}

@MainActor @Test func aSidebarInAWindowThatIsNotShownDoesNotCountAsInside() throws {
    let fixture = try Fixture()
    let otherWindow = KeyCatchingWindow()
    otherWindow.setFrameOrigin(NSPoint(x: 45_000, y: 45_000))
    // Ordered out or minimized, as the window server reports it.
    let other = fixture.makeSidebar()
    other.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)
    otherWindow.contentView?.addSubview(other.view)
    let onOther = otherWindow.convertPoint(
        toScreen: other.view.convert(NSPoint(x: 100, y: 250), to: nil))
    let documents = try #require(fixture.outline.item(atRow: try fixture.row(of: "Documents")))

    fixture.sidebar.beginDrag(of: [documents])
    fixture.sidebar.endDrag(at: onOther, operation: [])

    #expect(try !fixture.favoriteNames.contains("Documents"))
}

@MainActor @Test func aDragIsCancelledByAKeyDuringItOrAButtonStillDown() {
    let cancelled = WorkspaceSidebarViewController.wasCancelled
    // Esc during the drag, the button let go before the end reached the app.
    #expect(cancelled(0.05, 2, false))
    // Esc with the button still down.
    #expect(cancelled(30, 2, true))
    // A drop: the button released, no key since the drag began.
    #expect(!cancelled(30, 2, false))
}

@MainActor @Test func aDropBetweenTheLastFavoriteAndTheWorkspacesGoesAtTheEnd() throws {
    let fixture = try Fixture()

    // AppKit proposes the gap between the two groups, at the root.
    let operation = fixture.drop(fixture.drag(["/p/end"]), parentRow: -1, index: 1)

    #expect(!operation.isEmpty)
    #expect(try fixture.favoriteNames.last == "end")
    // Above the first group is no place among the favorites.
    #expect(fixture.drop(fixture.drag(["/p/top"]), parentRow: -1, index: 0).isEmpty)
}

@MainActor @Test func removeFromSidebarInAFavoritesMenuRemovesIt() throws {
    let fixture = try Fixture()
    #expect(fixture.sidebar.contextMenu(forRow: try fixture.row(of: "Alpha")) == nil)

    let menu = try #require(fixture.sidebar.contextMenu(forRow: try fixture.row(of: "Desktop")))
    let item = try #require(menu.items.first)
    #expect(item.title == "Remove from Sidebar")
    _ = (item.target as? NSObject)?.perform(item.action, with: item)

    #expect(try fixture.favoriteNames == ["Applications", "Documents", "Downloads", "u"])
}

@MainActor @Test func theSettingsHideEachGroupAndAGroupShownAgainIsExpanded() throws {
    let fixture = try Fixture()

    fixture.settings.showsFavoritesInSidebar = false
    #expect(fixture.groupTitles == ["Workspaces"])
    #expect(try fixture.favoriteCells.isEmpty)
    #expect(try fixture.names == ["Alpha", "beta", "Gamma"])

    fixture.settings.showsWorkspacesInSidebar = false
    #expect(fixture.outline.numberOfRows == 0)

    fixture.settings.showsFavoritesInSidebar = true
    #expect(fixture.groupTitles == ["Favorites"])
    #expect(try fixture.favoriteNames.count == 5)
    #expect(try fixture.cells.isEmpty)
}

@MainActor @Test func aFavoriteChangedInOneWindowShowsInAnother() throws {
    let fixture = try Fixture()
    let other = fixture.makeSidebar()
    other.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)

    fixture.drop(fixture.drag(["/p/new"]), parentRow: 0, index: 0)

    #expect(
        try fixture.cells(of: "favorite", in: other.outlineView).first?.textField?.stringValue
            == "new")
    fixture.favorites.remove("/p/new")
    #expect(try fixture.cells(of: "favorite", in: other.outlineView).count == 5)
}

@MainActor @Test func aFavoriteNotFoundIsGreyedAndSaysSo() async throws {
    let fixture = try Fixture()
    fixture.resolver.states = ["/Users/u/Downloads": .missing]

    fixture.favorites.refresh()

    await settle {
        (try? fixture.favoriteCells.map { $0.accessibilityLabel() ?? "" })?.contains(
            "Downloads, not found") == true
    }
    let downloads = try #require(
        try fixture.favoriteCells.first { $0.textField?.stringValue == "Downloads" })
    #expect(downloads.textField?.textColor == .tertiaryLabelColor)
}

/// As Finder's on macOS 26: thin outline symbols, not the filled `Sidebar*.icns` glyphs, which
/// the stub reads as red squares; only Applications, which no public symbol draws, shows its
/// file once read.
@MainActor @Test func favoritesAndVolumesShowFindersOutlineSymbols() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb, image, share])
    await fixture.icons.load()
    let applications = try #require(fixture.favoriteCells.first?.imageView)
    await settle { applications.image === fixture.icons.image(.applications) }

    #expect(applications.image?.isTemplate == true)
    #expect(String(describing: applications.image).contains("app.dashed") == false)
    let favorites = try fixture.favoriteCells.dropFirst().map(\.imageView?.image)
    let volumes = try fixture.volumeCells.map(\.imageView?.image)
    let symbols = [
        "dock.rectangle", "doc", "arrow.down.circle", "house", "externaldrive", "externaldrive",
        "externaldrive.connected.to.line.below",
    ]
    for (symbol, image) in zip(symbols, favorites + volumes) {
        let image = try #require(image)
        #expect(image.isTemplate, "\(symbol)")
        let description = String(describing: image)
        #expect(description.hasSuffix("symbol = \(symbol)>"), "\(description)")
    }
}

@Test func eachKindOfRowHasFindersSymbol() {
    let symbols = Dictionary(
        uniqueKeysWithValues: SidebarIcons.Glyph.allCases.map { ($0, $0.symbol) })
    #expect(
        symbols == [
            .applications: "app.dashed", .desktop: "dock.rectangle", .documents: "doc",
            .downloads: "arrow.down.circle", .home: "house", .folder: "folder",
            .externalDisk: "externaldrive", .internalDisk: "internaldrive",
            .removableDisk: "externaldrive", .server: "externaldrive.connected.to.line.below",
            .genericFile: "doc",
        ])
    #expect(SidebarIcons.Glyph.allCases.filter { $0.coreTypesFile != nil } == [.applications])
}

/// As Finder's, in both appearances: a glyph is drawn in the label color at rest, in the accent
/// on the selected row while the list doesn't have the keys, and white on the selected row while
/// that row is emphasized, as AppKit draws it while the list has the keys of the key window. The
/// rows measured are outline symbols, Desktop's, Documents' and a disk's.
@MainActor @Test func glyphsTakeTheLabelColorAtRestAndTheSelectedRowsColor() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb])
    await fixture.icons.load()
    await settle {
        (try? fixture.favoriteCells.first?.imageView?.image) === fixture.icons.image(.applications)
    }
    fixture.window.makeFirstResponder(nil)
    let desktop = try fixture.row(of: "Desktop")
    let atRest = [try fixture.row(of: "Documents"), try fixture.row(of: "USB")]
    fixture.outline.selectRowIndexes([desktop], byExtendingSelection: false)

    for name in [NSAppearance.Name.aqua, .darkAqua] {
        let appearance = try #require(NSAppearance(named: name))
        fixture.window.appearance = appearance
        var label = NSColor.clear
        var accent = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            label = NSColor.labelColor.usingColorSpace(.sRGB) ?? .clear
            accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .clear
        }
        let rowView = try #require(fixture.outline.rowView(atRow: desktop, makeIfNecessary: true))

        rowView.isEmphasized = false
        var colors = try glyphColors(in: fixture.outline, rows: [desktop] + atRest)
        for color in colors.dropFirst() {
            #expect(isClose(color, to: label), "\(name.rawValue): \(color) at rest")
        }
        #expect(hasHue(colors[0], of: accent), "\(name.rawValue): \(colors[0]) selected")

        rowView.isEmphasized = true
        colors = try glyphColors(in: fixture.outline, rows: [desktop] + atRest)
        #expect(isClose(colors[0], to: .white), "\(name.rawValue): \(colors[0]) emphasized")
        for color in colors.dropFirst() {
            #expect(isClose(color, to: label), "\(name.rawValue): \(color) at rest")
        }
    }
}

/// Draws `outline` and gives the color of each of `rows`' icons, in sRGB: the pixel in the icon
/// that differs most from the one at its corner, which is the row's background. An outline
/// symbol's center is often background, so the stroke's color is found by its contrast.
@MainActor
private func glyphColors(in outline: NSOutlineView, rows: [Int]) throws -> [NSColor] {
    let bitmap = try #require(outline.bitmapImageRepForCachingDisplay(in: outline.bounds))
    outline.cacheDisplay(in: outline.bounds, to: bitmap)
    let scale = CGFloat(bitmap.pixelsWide) / outline.bounds.width
    return try rows.map { row in
        let cell = try #require(
            outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)
        let icon = try #require(cell.imageView)
        let frame = outline.convert(icon.bounds, from: icon)
        let pixels = try stride(from: Int(frame.minX * scale), to: Int(frame.maxX * scale), by: 1)
            .flatMap { x in
                try stride(from: Int(frame.minY * scale), to: Int(frame.maxY * scale), by: 1)
                    .map { y in
                        try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    }
            }
        let background = try #require(pixels.first)
        let ink = try #require(
            pixels.max { inkContrast($0, background) < inkContrast($1, background) })
        return ink
    }
}

/// How far apart two pixels are, premultiplied, so a clear pixel is far from an opaque one
/// whatever their colors.
private func inkContrast(_ one: NSColor, _ other: NSColor) -> CGFloat {
    abs(one.redComponent * one.alphaComponent - other.redComponent * other.alphaComponent)
        + abs(one.greenComponent * one.alphaComponent - other.greenComponent * other.alphaComponent)
        + abs(one.blueComponent * one.alphaComponent - other.blueComponent * other.alphaComponent)
        + abs(one.alphaComponent - other.alphaComponent)
}

/// Whether `color` is `other`, give or take what drawing does to it. The alpha isn't compared: a
/// source list draws a template glyph opaque in the label color, whose alpha is under 1.
private func isClose(_ color: NSColor, to other: NSColor) -> Bool {
    guard let other = other.usingColorSpace(.sRGB) else { return false }
    return abs(color.redComponent - other.redComponent) < 0.1
        && abs(color.greenComponent - other.greenComponent) < 0.1
        && abs(color.blueComponent - other.blueComponent) < 0.1
}

/// Whether `color` is a shade of `accent`: AppKit draws the accent on a selected row a little
/// lighter than `controlAccentColor`, so the hue is compared, or, for a grey accent, the lack
/// of one.
private func hasHue(_ color: NSColor, of accent: NSColor) -> Bool {
    guard accent.saturationComponent > 0.3 else { return color.saturationComponent < 0.15 }
    return color.saturationComponent > 0.3 && abs(color.hueComponent - accent.hueComponent) < 0.04
}

/// As Finder's, Finder's glyphs take the size drawn for the system's sidebar icon size, which
/// gives the rows their size, and the eject glyph the small scale of the size AppKit gives a
/// sidebar's symbols: Finder's is about four fifths of a symbol at the row's size.
@MainActor @Test func glyphsFollowTheSidebarIconSize() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb])
    await fixture.icons.load()
    await settle {
        (try? fixture.favoriteCells.first?.imageView?.image) === fixture.icons.image(.applications)
    }
    let sides: [(NSTableView.RowSizeStyle, CGFloat)] = [(.small, 16), (.medium, 18), (.large, 24)]

    for (style, side) in sides {
        fixture.outline.rowSizeStyle = style
        fixture.outline.reloadData()
        fixture.outline.expandItem(nil, expandChildren: true)
        fixture.sidebar.view.layoutSubtreeIfNeeded()
        for cell in try fixture.favoriteCells + fixture.volumeCells {
            cell.layoutSubtreeIfNeeded()
            // A symbol's frame takes in its alignment insets; the box laid out is the side.
            let icon = try #require(cell.imageView)
            let laidOut = icon.alignmentRect(forFrame: icon.frame).size
            #expect(laidOut == NSSize(width: side, height: side), "\(style)")
        }
        let volume = try #require(fixture.volumeCells.first)
        let symbolSize = try #require(volume.imageView?.symbolConfiguration)
        let eject = try #require(volume.ejectButton.symbolConfiguration)
        #expect(eject == symbolSize.applying(.init(scale: .small)), "\(style)")
    }
}

/// Finder's eject glyph, filled, light at rest, darker under the mouse and darker still
/// pressed, faint while off, and the selected row's text color on an emphasized row.
@MainActor @Test func theEjectButtonShowsFindersGlyphDarkerUnderTheMouseAndPressed()
    async throws
{
    let fixture = try Fixture()
    await fixture.mount([usb])
    let eject = try #require(fixture.volumeCells.first).ejectButton
    let entered = try #require(
        NSEvent.enterExitEvent(
            with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))

    #expect(String(describing: eject.image).contains("eject.fill"))
    #expect(eject.fill == nil)
    #expect(eject.glyphTint == .tertiaryLabelColor)
    eject.mouseEntered(with: entered)
    #expect(eject.glyphTint == .secondaryLabelColor)
    #expect(eject.fill == nil)
    eject.highlight(true)
    #expect(eject.glyphTint == .labelColor)
    #expect(eject.fill == nil)
    eject.highlight(false)
    eject.isEnabled = false
    #expect(eject.glyphTint == .quaternaryLabelColor)
    eject.isEnabled = true
    eject.mouseExited(with: entered)
    #expect(eject.glyphTint == .tertiaryLabelColor)

    try #require(fixture.volumeCells.first).backgroundStyle = .emphasized
    #expect(eject.glyphTint == HoverButton.glyphTint(.rest, onEmphasizedSelection: true))
    eject.mouseEntered(with: entered)
    #expect(eject.glyphTint == HoverButton.glyphTint(.hovered, onEmphasizedSelection: true))
    try #require(fixture.volumeCells.first).backgroundStyle = .normal
    #expect(eject.glyphTint == .secondaryLabelColor)
}

@MainActor @Test func aGlyphTheBundleLacksShowsItsSymbol() async {
    let icons = SidebarIcons { _ in [:] }

    await icons.load()

    for glyph in SidebarIcons.Glyph.allCases {
        let description = String(describing: icons.image(glyph))
        #expect(description.hasSuffix("symbol = \(glyph.symbol)>"), "\(description)")
    }
}

@Test func finderPicksTheGlyphForEachKindOfFolderAndVolume() {
    typealias Glyph = SidebarIcons.Glyph
    #expect(Glyph.forFolder(at: "/Applications", home: "/Users/u") == .applications)
    #expect(Glyph.forFolder(at: "/Users/u", home: "/Users/u") == .home)
    #expect(Glyph.forFolder(at: "/Users/u/Downloads", home: "/Users/u") == .downloads)
    #expect(Glyph.forFolder(at: "/Users/u/Work", home: "/Users/u") == .folder)
    let card = SidebarVolume(
        mountPoint: "/Volumes/C", name: "C", kind: .local, isInternal: true, isRemovable: true)
    let internalDisk = SidebarVolume(
        mountPoint: "/Volumes/I", name: "I", kind: .local, isInternal: true)
    #expect(Glyph.forVolume(usb) == .externalDisk)
    #expect(Glyph.forVolume(image) == .externalDisk)
    #expect(Glyph.forVolume(share) == .server)
    #expect(Glyph.forVolume(card) == .removableDisk)
    #expect(Glyph.forVolume(internalDisk) == .internalDisk)
}

// MARK: Locations

private let startup = SidebarVolume(
    mountPoint: "/", name: "Macintosh HD", kind: .local, isRootFileSystem: true, isInternal: true)
private let usb = SidebarVolume(
    mountPoint: "/Volumes/USB", name: "USB", kind: .local, isInternal: false)
private let image = SidebarVolume(mountPoint: "/Volumes/Image", name: "Image", kind: .local)
private let share = SidebarVolume(mountPoint: "/Volumes/main", name: "main", kind: .network)

@MainActor @Test func locationsListsTheMountedVolumesBetweenFavoritesAndWorkspaces() async throws {
    let fixture = try Fixture()
    #expect(fixture.groupTitles == ["Favorites", "Workspaces"])

    await fixture.mount([startup, usb, image, share])

    #expect(fixture.groupTitles == ["Favorites", "Locations", "Workspaces"])
    #expect(try fixture.volumeNames == ["USB", "Image", "main"])
    #expect(try fixture.volumeCells.allSatisfy { !$0.ejectButton.isHidden && !$0.showsOpen })
    #expect(try fixture.volumeCells.allSatisfy { $0.imageView?.image != nil })
    #expect(try fixture.row(of: "u") < (try fixture.row(of: "USB")))
    #expect(try fixture.row(of: "main") < (try fixture.row(of: "Alpha")))
    #expect(try fixture.cells.allSatisfy { $0.ejectButton.isHidden })
}

@MainActor @Test func mountsAndUnmountsShowInEveryWindowsLocations() async throws {
    let fixture = try Fixture()
    let other = fixture.makeSidebar()
    other.view.frame = NSRect(x: 0, y: 0, width: 200, height: 300)

    await fixture.mount([usb, share])
    #expect(
        try fixture.cells(of: "volume", in: other.outlineView).map {
            $0.textField?.stringValue ?? ""
        } == ["USB", "main"])

    fixture.mounts.set([share])
    VolumeEvents.didUnmount(at: "/sidebar-test-\(UUID().uuidString)")
    await settle { (try? fixture.volumeNames) == ["main"] }
    #expect(try fixture.cells(of: "volume", in: other.outlineView).count == 1)

    await fixture.mount([])
    #expect(fixture.groupTitles == ["Favorites", "Workspaces"])
}

@MainActor @Test func returnOnAVolumeShowsIt() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb, share])
    fixture.outline.selectRowIndexes([try fixture.row(of: "main")], byExtendingSelection: false)

    fixture.outline.keyDown(with: try keyEvent("\r"))

    #expect(fixture.openedLocations == [Location(path: "/Volumes/main")])
    #expect(fixture.openedFavorites.isEmpty && fixture.opened.isEmpty)
}

@MainActor @Test func theEjectButtonEjectsOffTheMainThreadAndAlertsWhenItFails() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb, share])

    try #require(fixture.volumeCells.first).ejectButton.performClick(nil)
    await settle { fixture.mounts.ejects.count == 1 }
    #expect(fixture.mounts.ejects.map(\.mountPoint) == ["/Volumes/USB"])
    #expect(fixture.mounts.ejects.map(\.onBlockingThread) == [true])
    #expect(fixture.openedLocations.isEmpty)

    fixture.mounts.fail(with: "The volume is in use by another app.")
    try #require(fixture.volumeCells.last).ejectButton.performClick(nil)
    await settle { !fixture.alerts.isEmpty }
    #expect(fixture.mounts.ejects.map(\.mountPoint) == ["/Volumes/USB", "/Volumes/main"])
    let alert = try #require(fixture.alerts.first)
    #expect(alert.messageText == "The disk “main” wasn’t ejected.")
    #expect(alert.informativeText == "The volume is in use by another app.")
    #expect(fixture.alerts.count == 1)
}

@MainActor @Test func aVolumesContextMenuEjectsIt() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb])

    let menu = try #require(fixture.sidebar.contextMenu(forRow: try fixture.row(of: "USB")))
    let item = try #require(menu.items.first)
    #expect(menu.items.count == 1)
    #expect(item.title == "Eject “USB”")
    _ = (item.target as? NSObject)?.perform(item.action, with: item)

    await settle { fixture.mounts.ejects.count == 1 }
    #expect(fixture.mounts.ejects.map(\.mountPoint) == ["/Volumes/USB"])
    #expect(fixture.alerts.isEmpty)
}

@MainActor @Test func theLocationsSettingHidesTheGroupAndShowsItAgainExpanded() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb])

    fixture.settings.showsLocationsInSidebar = false
    #expect(fixture.groupTitles == ["Favorites", "Workspaces"])
    #expect(try fixture.volumeCells.isEmpty)

    fixture.settings.showsLocationsInSidebar = true
    #expect(fixture.groupTitles == ["Favorites", "Locations", "Workspaces"])
    #expect(try fixture.volumeNames == ["USB"])
}

@MainActor @Test func theArrowKeysCrossFromTheFavoritesThroughLocationsToTheWorkspaces()
    async throws
{
    let fixture = try Fixture()
    await fixture.mount([usb, share])
    fixture.outline.selectRowIndexes([try fixture.row(of: "u")], byExtendingSelection: false)
    let down = try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags)
    let up = try keyEvent(functionKey(NSUpArrowFunctionKey), modifiers: arrowFlags)

    fixture.outline.keyDown(with: down)
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "USB")))
    fixture.outline.keyDown(with: down)
    fixture.outline.keyDown(with: down)
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "Alpha")))
    fixture.outline.keyDown(with: up)
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "main")))
    fixture.outline.keyDown(with: up)
    fixture.outline.keyDown(with: up)
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "u")))
    #expect(fixture.openedLocations.isEmpty && fixture.openedFavorites.isEmpty)
    #expect(fixture.mounts.ejects.isEmpty)
}

@MainActor @Test func aCommandChordFromAVolumeRowGoesToThePane() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb])
    fixture.outline.selectRowIndexes([try fixture.row(of: "USB")], byExtendingSelection: false)
    var passed: [NSEvent] = []
    fixture.sidebar.outlineView.passKey = { event in
        passed.append(event)
        return true
    }

    fixture.outline.keyDown(with: try keyEvent("o", modifiers: .command))

    #expect(passed.count == 1)
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "USB")))
    #expect(fixture.openedLocations.isEmpty)
}

@MainActor @Test func aVolumesEjectButtonIsOffWhileItsEjectRunsAndARepeatIsIgnored()
    async throws
{
    let fixture = try Fixture()
    await fixture.mount([usb])
    fixture.mounts.holdEjects()
    // The list tells its observers as an eject starts and as it ends.
    var changes = 0
    fixture.volumes.observe(for: fixture) { changes += 1 }

    try #require(fixture.volumeCells.first).ejectButton.performClick(nil)
    await settle { (try? fixture.volumeCells.first?.ejectButton.isEnabled) == false }
    let menu = try #require(fixture.sidebar.contextMenu(forRow: try fixture.row(of: "USB")))
    let item = try #require(menu.items.first)
    _ = (item.target as? NSObject)?.perform(item.action, with: item)
    #expect(fixture.mounts.ejects.count == 1)

    fixture.mounts.releaseEjects()
    await settle { changes == 2 }
    // Ejected, the row keeps its button off while a read still lists the volume.
    await fixture.mount([usb])
    #expect(try fixture.volumeCells.first?.ejectButton.isEnabled == false)
    await fixture.mount([])
    #expect(try fixture.volumeCells.isEmpty)
    // A volume mounted later at the same place can be ejected.
    await fixture.mount([usb])
    await settle { (try? fixture.volumeCells.first?.ejectButton.isEnabled) == true }
    #expect(fixture.mounts.ejects.count == 1)
    #expect(fixture.alerts.isEmpty)
}

@MainActor @Test func aRefusedEjectTurnsTheButtonBackOn() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb])
    fixture.mounts.fail(with: "The volume is in use.")

    try #require(fixture.volumeCells.first).ejectButton.performClick(nil)

    await settle { !fixture.alerts.isEmpty }
    #expect(try fixture.volumeCells.first?.ejectButton.isEnabled == true)
}

// MARK: Servers

private let halMain = SidebarVolume(
    mountPoint: "/Volumes/main", name: "main", kind: .network, server: testServer)
private let halMusic = SidebarVolume(
    mountPoint: "/Volumes/music", name: "music", kind: .network, server: testServer)

@MainActor @Test func aServersSharesAreOneRowWhereItsFirstShareIsWithFindersGlyph() async throws {
    let fixture = try Fixture()

    await fixture.mount([usb, halMain, image, halMusic])
    await fixture.icons.load()

    #expect(try fixture.volumeNames == ["USB", "HAL9000", "Image"])
    let server = try fixture.volumeCells[1]
    await settle { server.imageView?.image === fixture.icons.image(.genericFile) }
    #expect(!server.ejectButton.isHidden && server.ejectButton.isEnabled)
    #expect(server.accessibilityLabel() == "HAL9000")
}

@MainActor @Test func aClickOrReturnOnAServerShowsIt() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb, halMain, halMusic])

    fixture.sidebar.openClicked(row: try fixture.row(of: "HAL9000"))
    await settle { !fixture.openedLocations.isEmpty }
    fixture.outline.selectRowIndexes([try fixture.row(of: "HAL9000")], byExtendingSelection: false)
    fixture.outline.keyDown(with: try keyEvent("\r"))

    #expect(fixture.openedLocations == [.server(testServer), .server(testServer)])
}

/// The server's row stays selected while the sidebar has the keys, across a reload that makes
/// new rows, as a volume's row does by its mount point.
@MainActor @Test func aSelectedServerRowStaysSelectedAfterAReload() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb, halMain, halMusic])
    #expect(fixture.window.makeFirstResponder(fixture.outline))
    fixture.outline.selectRowIndexes([try fixture.row(of: "HAL9000")], byExtendingSelection: false)

    await fixture.mount([halMain, image, halMusic])

    #expect(try fixture.volumeNames == ["HAL9000", "Image"])
    #expect(fixture.outline.selectedRow == (try fixture.row(of: "HAL9000")))
}

@MainActor @Test func aServersEjectButtonEjectsEveryShareAndIsOffWhileAnyRuns() async throws {
    let fixture = try Fixture()
    await fixture.mount([halMain, halMusic])
    fixture.mounts.holdEjects()

    try #require(fixture.volumeCells.first).ejectButton.performClick(nil)

    await settle { fixture.mounts.ejects.count == 2 }
    #expect(Set(fixture.mounts.ejects.map(\.mountPoint)) == ["/Volumes/main", "/Volumes/music"])
    #expect(try fixture.volumeCells.first?.ejectButton.isEnabled == false)
    fixture.mounts.releaseEjects()
    // Ejected, the row keeps its button off while a read still lists a share.
    await fixture.mount([halMusic])
    #expect(try fixture.volumeCells.first?.ejectButton.isEnabled == false)
    await fixture.mount([])
    #expect(try fixture.volumeCells.isEmpty)
    #expect(fixture.alerts.isEmpty)
    #expect(fixture.openedLocations.isEmpty)
}

@MainActor @Test func aServersContextMenuEjectsEveryShare() async throws {
    let fixture = try Fixture()
    await fixture.mount([halMain, halMusic])

    let menu = try #require(fixture.sidebar.contextMenu(forRow: try fixture.row(of: "HAL9000")))
    let item = try #require(menu.items.first)
    #expect(menu.items.count == 1)
    #expect(item.title == "Eject “HAL9000”")
    _ = (item.target as? NSObject)?.perform(item.action, with: item)

    await settle { fixture.mounts.ejects.count == 2 }
    #expect(fixture.alerts.isEmpty)
}

@MainActor @Test func oneRefusedShareOfAServerShowsTheDisksAlert() async throws {
    let fixture = try Fixture()
    await fixture.mount([halMain, halMusic])
    fixture.mounts.fail("/Volumes/main", with: "The volume is in use.")

    try #require(fixture.volumeCells.first).ejectButton.performClick(nil)

    await settle { !fixture.alerts.isEmpty }
    let alert = try #require(fixture.alerts.first)
    #expect(alert.messageText == "The disk “main” wasn’t ejected.")
    #expect(alert.informativeText == "The volume is in use.")
    #expect(fixture.mounts.ejects.count == 2)
}

@MainActor @Test func twoRefusedSharesOfAServerShowOneAlertWithEachReason() async throws {
    let fixture = try Fixture()
    await fixture.mount([halMain, halMusic])
    fixture.mounts.fail("/Volumes/main", with: "The volume is in use.")
    fixture.mounts.fail("/Volumes/music", with: "A file is open.")

    try #require(fixture.volumeCells.first).ejectButton.performClick(nil)

    await settle { !fixture.alerts.isEmpty }
    let alert = try #require(fixture.alerts.first)
    #expect(alert.messageText == "The disks “main” and “music” weren’t ejected.")
    #expect(alert.informativeText == "The volume is in use.\nA file is open.")
    #expect(fixture.alerts.count == 1)
    #expect(try fixture.volumeCells.first?.ejectButton.isEnabled == true)
}

@MainActor @Test func threeRefusedSharesAreListedWithCommas() {
    let alert = WorkspaceSidebarViewController.ejectFailedAlert(
        ["a", "b", "c"].map { .init(name: $0, reason: "No.") })

    #expect(alert.messageText == "The disks “a”, “b”, and “c” weren’t ejected.")
    #expect(alert.informativeText == "No.\nNo.\nNo.")
}

@MainActor @Test func nothingDropsOnAServersRow() async throws {
    let fixture = try Fixture()
    await fixture.mount([halMain, halMusic])
    let server = try fixture.row(of: "HAL9000")

    #expect(
        fixture.drop(
            fixture.drag(["/p/new"]), parentRow: server, index: NSOutlineViewDropOnItemIndex
        ).isEmpty)
    #expect(!fixture.settings.favorites.map(\.path).contains("/p/new"))
}
