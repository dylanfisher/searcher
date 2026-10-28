import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// The tags of the item at `path`, read off the main thread.
func tags(_ path: String) async throws -> [String] {
    try await BlockingCallThread.run { () throws(FileOperationError) -> [String] in
        try FinderTags.entries(at: path)
    }
}

/// Gives the item at `path` the tag entries `entries`, off the main thread, as Finder writes
/// them.
func setTags(_ entries: [String], at path: String) async throws {
    let unlabeled = try await BlockingCallThread.run {
        () throws(FileOperationError) -> FileOperationError? in
        try FinderTags.set(entries: entries, at: path)
    }
    #expect(unlabeled == nil)
}

/// A window at a real temporary folder of tagged files: its pane, list or columns, its table's
/// commands, the app's queue and the undo history that follows it. Nothing is faked; the window
/// is never shown unless a test orders it in on the second display
/// (docs/decisions/0121-tag-commands.md, docs/decisions/0124-tags-in-rows-and-preview.md).
@MainActor
struct TaggingWindow {
    let folder: TemporaryFolder
    let pane: Pane
    let history = UndoHistory(log: { _ in })
    let controller: BrowserWindowController
    let paneController: PaneViewController

    /// A window at a folder holding `files`, each with its tags, and the empty folders
    /// `folders`, in `viewMode`. With `monitorsFolders`, the folder's FSEvents patch its rows.
    init(
        _ files: [(name: String, tags: [String])], folders: [String] = [],
        viewMode: ViewMode = .list, monitorsFolders: Bool = false
    ) async throws {
        folder = try TemporaryFolder("TaggingWindow")
        for name in folders {
            try FileManager.default.createDirectory(
                at: folder.url.appending(path: name), withIntermediateDirectories: false)
        }
        for file in files {
            let path = folder.url.appending(path: file.name).path
            try Data(file.name.utf8).write(to: URL(fileURLWithPath: path))
            if !file.tags.isEmpty { try await setTags(file.tags, at: path) }
        }
        let settings = untouchedSettings()
        let pane = Pane(
            location: Location(path: folder.url.path), service: ListingService(),
            systemActions: StubSystemActions(), settings: settings, isFocused: true,
            viewMode: viewMode)
        self.pane = pane
        let (finished, feed) = AsyncStream.makeStream(of: FileOperationQueue.Snapshot.self)
        history.follow(finished)
        let queue = FileOperationQueue(
            prompts: .unexpected, onChange: { _ in }, onAnyFinish: { feed.yield($0) })
        let volumes = StubSidebarVolumes([]).list()
        var made: PaneViewController?
        controller = BrowserWindowController(
            workspace: Workspace(tab: Tab(pane: pane)), workspaces: WorkspaceList(),
            favorites: Favorites(settings: settings), volumes: volumes, settings: settings,
            fileOperations: queue, undoHistory: history,
            takePaneController: { _, pane in
                let controller = PaneViewController(
                    pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
                    tableView: ListingTableView(), monitorsFolders: monitorsFolders)
                made = controller
                return controller
            })
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        paneController = try #require(made)
        let registry = try AppCommands.registry()
        paneController.listingViewController.tableView.registry = registry
        if viewMode == .list {
            await settle { pane.state.isLoaded }
        } else {
            // The columns list the folders, from the root down; the pane lists none itself.
            let location = Location(path: folder.url.path)
            await settle {
                pane.columnTrail?.columns.contains {
                    $0.pane.location == location && $0.pane.state.isLoaded
                } == true
            }
            window.contentView?.layoutSubtreeIfNeeded()
            for column in paneController.columnViewController.columnControllers {
                column.tableView.registry = registry
            }
        }
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func path(_ name: String) -> String { folder.url.appending(path: name).path }

    /// The list showing the folder: the list, or the folder's column.
    var list: ListingViewController {
        get throws {
            guard pane.columnTrail != nil else { return paneController.listingViewController }
            let location = Location(path: folder.url.path)
            return try #require(
                paneController.columnViewController.columnControllers.first {
                    $0.pane.location == location
                })
        }
    }

    /// The pane listing the folder: the pane, or the folder's column's.
    var folderPane: Pane {
        get throws { try list.pane }
    }

    func row(of name: String) throws -> Int {
        try #require(try folderPane.state.listing?.row(named: name))
    }

    /// The tag dots of the menu a right-click on `name`'s row gets, once they show the
    /// selection's tags, turned on as when the menu opens.
    func dots(onRowOf name: String) async throws -> TagDotsView {
        let menu = try list.contextMenu(forRow: try row(of: name))
        let dots = try #require(menu.items.lazy.compactMap { $0.view as? TagDotsView }.first)
        await settle { dots.hasTags }
        dots.validate()
        return dots
    }

    /// The Name cell of `name`'s row.
    func nameCell(of name: String) throws -> ListingNameCellView {
        let cell = try list.shownNameCell(atRow: try row(of: name))
        return try #require(cell as? ListingNameCellView)
    }

    /// The tag dots `name`'s row shows, nil when it shows none.
    func rowDots(of name: String) throws -> RowTagDotsView? {
        try nameCell(of: name).tagDots.flatMap { $0.isHidden ? nil : $0 }
    }

    func dot(_ name: String, in dots: TagDotsView) throws -> TagDotButton {
        try #require(dots.dots.first { $0.finderTag.name == name })
    }
}
