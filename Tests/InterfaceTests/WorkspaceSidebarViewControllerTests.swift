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
        defaults: temporarySuite(in: FileManager.default.temporaryDirectory.path), home: "/Users/u")
    let resolver = StubResolver()
    let favorites: Favorites
    var openedFavorites: [String] = []
    let mounts = StubSidebarVolumes()
    let volumes: SidebarVolumes
    var openedVolumes: [String] = []
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
            tabs: alpha.tabs.map(\.state), selectedTab: 0, showsSidebar: false)
        try list.addSaved(gamma)
        let resolver = resolver
        favorites = Favorites(settings: settings) { resolver.resolve($0) }
        volumes = mounts.list()
        sidebar = WorkspaceSidebarViewController(
            workspace: own, list: list, favorites: favorites, volumes: volumes, settings: settings)
        sidebar.open = { [weak self] id in self?.opened.append(id) }
        sidebar.openFavorite = { [weak self] path in self?.openedFavorites.append(path) }
        sidebar.openVolume = { [weak self] path in self?.openedVolumes.append(path) }
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
            workspace: own, list: list, favorites: favorites, volumes: volumes, settings: settings)
    }

    /// Mounts `volumes` in place of those mounted, as the system reports a mount at a mount point
    /// no other test uses, and waits for the rows to show them.
    func mount(_ volumes: [SidebarVolume]) async {
        mounts.set(volumes)
        VolumeEvents.didMount(at: "/sidebar-test-\(UUID().uuidString)")
        let names = volumes.filter(\.isShown).map(\.name)
        await settle { (try? self.volumeNames) == names }
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
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(paths.map { URL(fileURLWithPath: $0, isDirectory: true) as NSURL })
        return StubDraggingInfo(pasteboard: pasteboard)
    }

    /// A drag's info carrying the favorite in `row`, as the sidebar's list writes it.
    func dragFavorite(row: Int) throws -> StubDraggingInfo {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
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

    #expect(fixture.openedVolumes == ["/Volumes/main"])
    #expect(fixture.openedFavorites.isEmpty && fixture.opened.isEmpty)
}

@MainActor @Test func theEjectButtonEjectsOffTheMainThreadAndAlertsWhenItFails() async throws {
    let fixture = try Fixture()
    await fixture.mount([usb, share])

    try #require(fixture.volumeCells.first).ejectButton.performClick(nil)
    await settle { fixture.mounts.ejects.count == 1 }
    #expect(fixture.mounts.ejects.map(\.mountPoint) == ["/Volumes/USB"])
    #expect(fixture.mounts.ejects.map(\.onBlockingThread) == [true])
    #expect(fixture.openedVolumes.isEmpty)

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
    #expect(fixture.openedVolumes.isEmpty && fixture.openedFavorites.isEmpty)
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
    #expect(fixture.openedVolumes.isEmpty)
}
