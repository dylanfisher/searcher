import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// The row menu's tag dots, driven through a real window: its pane and list over a real
// temporary folder, its table's commands, the app's queue and the undo history that follows
// it. Nothing is faked; the window is never shown (docs/decisions/0121-tag-commands.md).

/// The tags of the item at `path`, read off the main thread.
private func tags(_ path: String) async throws -> [String] {
    try await BlockingCallThread.run { () throws(FileOperationError) -> [String] in
        try FinderTags.entries(at: path)
    }
}

@MainActor
private struct TaggingWindow {
    let folder: TemporaryFolder
    let pane: Pane
    let history = UndoHistory(log: { _ in })
    let controller: BrowserWindowController
    let list: ListingViewController

    /// A window at a folder holding `files`, each with its tags.
    init(_ files: [(name: String, tags: [String])]) async throws {
        folder = try TemporaryFolder("RowMenuTagTests")
        for file in files {
            let path = folder.url.appending(path: file.name).path
            try Data(file.name.utf8).write(to: URL(fileURLWithPath: path))
            let tags = file.tags
            let unlabeled = try await BlockingCallThread.run {
                () throws(FileOperationError) -> FileOperationError? in
                try FinderTags.set(entries: tags, at: path)
            }
            #expect(unlabeled == nil)
        }
        let settings = untouchedSettings()
        let pane = Pane(
            location: Location(path: folder.url.path), service: ListingService(),
            systemActions: StubSystemActions(), settings: settings, isFocused: true)
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
                    tableView: ListingTableView(), monitorsFolders: false)
                made = controller
                return controller
            })
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        list = try #require(made).listingViewController
        list.tableView.registry = try AppCommands.registry()
        await settle { pane.state.isLoaded }
    }

    func path(_ name: String) -> String { folder.url.appending(path: name).path }

    func row(of name: String) throws -> Int {
        try #require(pane.state.listing?.row(named: name))
    }

    /// The tag dots of the menu a right-click on `name`'s row gets, once they show the
    /// selection's tags, turned on as when the menu opens.
    func dots(onRowOf name: String) async throws -> TagDotsView {
        let menu = list.contextMenu(forRow: try row(of: name))
        let dots = try #require(menu.items.lazy.compactMap { $0.view as? TagDotsView }.first)
        await settle { dots.hasTags }
        dots.validate()
        return dots
    }

    func dot(_ name: String, in dots: TagDotsView) throws -> TagDotButton {
        try #require(dots.dots.first { $0.finderTag.name == name })
    }
}

@MainActor @Test func aRowMenuDotTagsTheSelectionThroughTheQueueAndUndoTakesItOff() async throws {
    let window = try await TaggingWindow([("a.txt", ["Red", "Work"]), ("b.txt", [])])
    window.pane.select(
        Selection([ExactName("a.txt"), ExactName("b.txt")], cursor: ExactName("b.txt")))

    let dots = try await window.dots(onRowOf: "b.txt")
    let red = try window.dot("Red", in: dots)
    // One of the two has Red: the dot shows a dash, and a click adds it to the other.
    #expect(red.coverage == .someItems)
    #expect(red.mark == .dash)
    #expect(red.isEnabled)
    #expect(red.accessibilityLabel() == "Add Tag “Red”")
    #expect(try window.dot("Blue", in: dots).coverage == .noItems)

    // What a mouse-up on the dot sends.
    #expect(red.sendAction(red.action, to: red.target))
    await settle { window.history.undoTitle == "Undo Add Tag “Red”" }

    #expect(try await tags(window.path("a.txt")) == ["Red", "Work"])
    #expect(try await tags(window.path("b.txt")) == ["Red\n6"])
    let after = try window.dot("Red", in: try await window.dots(onRowOf: "b.txt"))
    #expect(after.coverage == .allItems)
    #expect(after.mark == .check)
    #expect(after.accessibilityLabel() == "Remove Tag “Red”")

    window.list.tableView.run(UndoCommands.undo.id)
    await settle { window.history.redoTitle == "Redo Add Tag “Red”" }

    #expect(try await tags(window.path("a.txt")) == ["Red", "Work"])
    #expect(try await tags(window.path("b.txt")) == [])
}

@MainActor @Test func theFileMenusTagItemsShowTheirColorsAndRunOnTheSelection() async throws {
    let window = try await TaggingWindow([("a.txt", [])])
    window.pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let bar = try MainMenuBuilder.build(appName: "Searcher", registry: AppCommands.registry())
    let file = try #require(bar.items.first { $0.title == "File" }?.submenu)
    let tagsMenu = try #require(file.items.first { $0.title == TagCommands.menuTitle }?.submenu)
    let shown = tagsMenu.items.filter { !$0.isHidden }

    #expect(shown.map(\.title) == FinderTag.all.map { "\($0.name) Tag" })
    #expect(shown.allSatisfy { $0.image != nil })

    let green = try #require(shown.first { $0.title == "Green Tag" })
    #expect(window.list.tableView.validateMenuItem(green))
    window.list.tableView.runMenuCommand(green)
    await settle { window.history.undoTitle == "Undo Add Tag “Green”" }
    #expect(try await tags(window.path("a.txt")) == ["Green\n2"])
}
