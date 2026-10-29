import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// Another app's Show in Finder, with Searcher as the file viewer, shows each item selected in its
// folder (docs/decisions/0137-default-file-viewer.md).

/// A folder on disk holding `a.txt`, `b.txt`, `c.txt` and `docs/inside.txt`, and windows over
/// the real listing service that are never shown.
@MainActor
private struct RevealFixture {
    let folder: TemporaryFolder
    let windows: WorkspaceWindows

    init() throws {
        folder = try TemporaryFolder("WorkspaceWindowsRevealTests")
        let root = folder.url.path
        try FileManager.default.createDirectory(
            atPath: root + "/docs", withIntermediateDirectories: false)
        for name in ["a.txt", "b.txt", "c.txt", "docs/inside.txt"] {
            try Data(name.utf8).write(to: URL(fileURLWithPath: root + "/" + name))
        }
        windows = WorkspaceWindows(
            service: ListingService(), mountTable: MountTable(),
            systemActions: StubSystemActions(), settings: untouchedSettings(), folderSizes: nil,
            clipboard: MemoryClipboard(), store: nil)
        windows.showsWindows = false
    }

    var root: String { folder.url.path }

    /// The URL of `relative` under the folder, as an open event names it.
    func url(_ relative: String, isFolder: Bool = false) -> URL {
        URL(fileURLWithPath: root + "/" + relative, isDirectory: isFolder)
    }

    /// The window whose focused pane is at `path`.
    func controller(at path: String) throws -> BrowserWindowController {
        try #require(
            windows.controllers.first {
                $0.workspace.selectedTab.focusedPane.location == Location(path: path)
            })
    }

    /// The names selected in `controller`'s focused pane, once its folder is listed in full and
    /// its selection settled, sorted.
    func selectedNames(in controller: BrowserWindowController) async -> [String] {
        let pane = controller.workspace.selectedTab.focusedPane.commandPane
        await settle {
            pane.state.isLoaded && pane.state.listing?.count ?? 0 > 0 && pane.selection.isSettled
                && !pane.selectedEntries.isEmpty
        }
        return pane.selectedEntries.map(\.name).sorted()
    }

    func stop() {
        for controller in windows.controllers {
            controller.workspace.selectedTab.focusedPane.monitor?.stop()
        }
    }
}

/// Items in one folder share a window with all of them selected, a folder among them selected
/// rather than opened; an item in another folder gets a window of its own, in front.
@MainActor @Test func aRevealSelectsItsItemsInAWindowPerFolder() async throws {
    let fixture = try RevealFixture()
    defer { fixture.stop() }

    fixture.windows.reveal([
        fixture.url("a.txt"), fixture.url("docs/inside.txt"),
        fixture.url("docs", isFolder: true), fixture.url("c.txt"),
    ])

    #expect(fixture.windows.controllers.count == 2)
    let root = try fixture.controller(at: fixture.root)
    let docs = try fixture.controller(at: fixture.root + "/docs")
    #expect(await fixture.selectedNames(in: root) == ["a.txt", "c.txt", "docs"])
    #expect(await fixture.selectedNames(in: docs) == ["inside.txt"])
    #expect(fixture.windows.list.workspaces.count == 2)
}

/// A window already showing the folder is brought to the front and selects the items, and no
/// window opens.
@MainActor @Test func aRevealReusesAWindowShowingTheFolder() async throws {
    let fixture = try RevealFixture()
    defer { fixture.stop() }
    let shown = fixture.windows.open(at: Location(path: fixture.root))
    let pane = shown.workspace.selectedTab.focusedPane
    await settle { pane.state.isLoaded }
    fixture.windows.open(at: Location(path: fixture.root + "/docs"))
    #expect(fixture.windows.list.workspaces.first !== shown.workspace)

    fixture.windows.reveal([fixture.url("b.txt"), fixture.url("c.txt")])

    #expect(fixture.windows.controllers.count == 2)
    #expect(fixture.windows.list.workspaces.first === shown.workspace)
    #expect(await fixture.selectedNames(in: shown) == ["b.txt", "c.txt"])
}

/// A reveal that comes while the last session is read waits for the restore, then opens in
/// front; with nothing restored, its window is the one the restore hands back, in place of the
/// home window.
@MainActor @Test func aRevealDuringTheRestoreWaitsForIt() async throws {
    let fixture = try RevealFixture()
    defer { fixture.stop() }
    fixture.windows.holdSavesUntilRestore()

    fixture.windows.reveal([fixture.url("b.txt")])
    #expect(fixture.windows.controllers.isEmpty)

    let key = await fixture.windows.restore(
        WorkspaceStore.Contents(session: nil, workspaces: [:], snapshots: [:]))

    let opened = try fixture.controller(at: fixture.root)
    #expect(key === opened)
    #expect(await fixture.selectedNames(in: opened) == ["b.txt"])
}
