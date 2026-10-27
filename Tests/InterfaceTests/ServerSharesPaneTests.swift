import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// A pane at a server lists the shares the server offers: its mounted shares, and a row for each
// one it lists that isn't mounted, with a notice when the list couldn't be had. A share that
// isn't mounted takes no drop, drags nothing and turns off every command on the selection
// (docs/decisions/0115-server-shares.md). Each test goes through the real listing service,
// panes, views and mount table; the mounts, `smbutil` and the clock are stubs.

/// HAL9000's request for its share list, as the user its shares are mounted by.
private let dylans = ShareRequest(server: testServer, user: "dylan")

/// What the shares hold, for a pane that goes into one.
private let folders: [String: [DirectoryEntry]] = [
    "/": [folder("Volumes")],
    "/Volumes": [folder("main"), folder("music")],
    "/Volumes/main": [file("n.txt")],
    "/Volumes/music": [folder("a"), file("m.txt")],
    "/Volumes/music/a": [file("x.txt")],
]

/// The mounts, the share list and the clock a test's panes list a server from.
@MainActor
private final class World {
    let clock = ManualClock()
    let enumerator: GatedShareEnumerator
    let mounts: StubMounts
    let table: MountTable
    let shares: ServerShares
    let service: ListingService

    init(_ volumes: [VolumeIdentity], startError: ShareListError? = nil) async {
        enumerator = GatedShareEnumerator(startError: startError)
        mounts = StubMounts(volumes)
        table = mounts.table()
        await table.firstRead()
        shares = ServerShares(enumerator: enumerator, clock: clock)
        service = ListingService(
            lister: StubLister(folders), clock: clock, mounts: table, shares: shares)
    }

    /// Reads the table again with `volumes` mounted, and returns once the read has landed.
    func remount(_ volumes: [VolumeIdentity]) async {
        mounts.set(volumes)
        table.refresh()
        await settle { self.table.volumes == volumes }
    }

    /// Answers the share list's run once it has started its `count`th.
    func answer(_ result: Result<ShareList, ShareListError>, start count: Int = 1) async {
        #expect(await enumerator.waitForStarts(count))
        enumerator.answer(dylans, with: result)
    }
}

/// A focused pane at `testServer` in `viewMode`, in a window with a clipboard, a queue, the
/// world's mount table and `volumes` in its sidebar.
@MainActor
private struct Window {
    let pane: Pane
    let controller: BrowserWindowController
    let paneController: PaneViewController
    let clipboard: CutState
    let systemActions = StubSystemActions()

    init(
        _ world: World, viewMode: ViewMode = .list,
        volumes: SidebarVolumes = StubSidebarVolumes([]).list()
    ) throws {
        let settings = untouchedSettings()
        pane = Pane(
            location: .server(testServer), service: world.service,
            systemActions: systemActions, settings: settings, isFocused: true,
            viewMode: viewMode)
        clipboard = CutState(clipboard: MemoryClipboard())
        var made: PaneViewController?
        controller = BrowserWindowController(
            workspace: Workspace(tab: Tab(pane: pane)), workspaces: WorkspaceList(),
            favorites: Favorites(settings: settings), volumes: volumes, settings: settings,
            fileOperations: FileOperationQueue(prompts: .unexpected) { _ in },
            clipboard: clipboard, mountTable: world.table,
            takePaneController: { _, pane in
                let controller = PaneViewController(
                    pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
                    tableView: ListingTableView(), monitorsFolders: false)
                made = controller
                return controller
            })
        let window = try #require(controller.window)
        window.contentView?.layoutSubtreeIfNeeded()
        paneController = try #require(made)
    }

    /// The pane at the server: the list's, or the server's column.
    var serverPane: Pane {
        pane.columnTrail?.columns.first?.pane ?? pane
    }

    /// The list showing the server's rows: the list's, or the server's column.
    var serverList: ListingViewController {
        get throws {
            guard pane.columnTrail != nil else { return paneController.listingViewController }
            return try #require(paneController.columnViewController.columnControllers.first)
        }
    }

    /// The server's rows, once it shows `names`, with the commands' registry on its table.
    func shows(_ names: [String]) async throws -> ListingViewController {
        await settle { self.serverPane.state.names == names }
        try #require(serverPane.state.names == names)
        let list = try serverList
        list.tableView.registry = try AppCommands.registry()
        return list
    }

    /// Selects the rows `names` of the server.
    func select(_ names: [String]) {
        let exact = names.map(ExactName.init)
        serverPane.select(Selection(Set(exact), cursor: exact.first))
    }

    /// The note under the path bar, nil while it is hidden.
    var note: String? {
        let note = paneController.status.note
        return note.isHidden ? nil : note.stringValue
    }
}

extension ListingState {
    /// The names of the rows shown, in their order; empty with none.
    fileprivate var names: [String] {
        guard let listing else { return [] }
        return (0..<listing.count).map { listing[$0].name }
    }

    /// The types of the rows shown, by name.
    fileprivate var types: [String: DirectoryEntry.FileType] {
        guard let listing else { return [:] }
        return Dictionary(
            uniqueKeysWithValues: (0..<listing.count).map {
                (listing[$0].name, listing[$0].type)
            })
    }

    fileprivate var isServerListed: Bool {
        if case .serverListed = self { true } else { false }
    }
}

// MARK: The rows

@MainActor @Test(arguments: [ViewMode.list, .column])
func aMountedShareAndTheTwoTheServerListsAreThreeRowsOneEjecting(_ viewMode: ViewMode)
    async throws
{
    let world = await World([mountedShare("music")])
    let volumes = StubSidebarVolumes([
        SidebarVolume(mountPoint: "/Volumes/music", name: "music", kind: .network)
    ]).list()
    await settle { volumes.volumes.count == 1 }
    let window = try Window(world, viewMode: viewMode, volumes: volumes)
    await world.answer(.success(["docker", "main", "music"]))

    let list = try await window.shows(["docker", "main", "music"])

    #expect(window.serverPane.state.isLoaded)
    #expect(
        window.serverPane.state.types == [
            "docker": .unmountedShare, "main": .unmountedShare, "music": .directory,
        ])
    let ejects = (0..<3).map { row in
        list.contextMenu(forRow: row).items.contains { $0.title.hasPrefix("Eject") }
    }
    #expect(ejects == [false, false, true])
    let name = try #require(list.tableView.tableColumns.first { $0.title == "Name" })
    for row in 0..<3 {
        let cell = try #require(
            list.tableView(list.tableView, viewFor: name, row: row) as? NSTableCellView)
        if let cell = cell as? ColumnNameCellView {
            // Every share has a chevron, as in Finder, mounted or not.
            #expect(!cell.chevron.isHidden)
        }
        guard viewMode == .list else { continue }
        for title in ["Kind", "Size", "Date Modified"] {
            let column = try #require(list.tableView.tableColumns.first { $0.title == title })
            let text =
                (list.tableView(list.tableView, viewFor: column, row: row)
                as? NSTableCellView)?.textField?.stringValue
            #expect(text == (title == "Kind" ? "Volume" : "--"))
        }
    }
    #expect(window.note == nil)
}

@MainActor @Test func aShareMountedLaterIsOneMountedRow() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    await world.answer(.success(["main", "music"]))
    _ = try await window.shows(["main", "music"])

    await world.remount([mountedShare("music"), mountedShare("main")])

    await settle { window.pane.state.types["main"] == .directory }
    #expect(window.pane.state.names == ["main", "music"])
    // The list is cached for its lifetime, so the change ran no second list.
    #expect(world.enumerator.starts.count == 1)
}

@MainActor @Test func twoMountsOfOneShareAreTwoRowsAndNoUnmountedOne() async throws {
    let second = VolumeIdentity(
        device: "//guest@\(testServerHost)/main", mountPoint: "/Volumes/main 1",
        kind: .network, fsType: VolumeIdentity.smbFSType)
    let world = await World([mountedShare("main"), second])
    let window = try Window(world)
    await world.answer(.success(["main", "music"]))

    _ = try await window.shows(["main", "main 1", "music"])
    #expect(
        window.pane.state.types == [
            "main": .directory, "main 1": .directory, "music": .unmountedShare,
        ])
}

/// SMB share names don't tell case apart, and the system may hand a name decomposed.
@MainActor @Test func aListedNameMatchesAMountedShareOfAnotherCase() async throws {
    let world = await World([mountedShare("Music")])
    let window = try Window(world)
    await world.answer(.success(["music", "main"]))

    _ = try await window.shows(["main", "Music"])
    #expect(window.pane.state.types == ["main": .unmountedShare, "Music": .directory])
}

// MARK: Notices

@MainActor
@Test(
    arguments: [
        (ShareListError.rejected, "The server rejected the password."),
        (.unreachable, "The server isn't answering."),
        (.failed("smbutil: server connection failed"), "smbutil: server connection failed"),
        (.unparsable, "The server's reply wasn't understood."),
        (.toolMissing, "The server's reply wasn't understood."),
    ])
func aListThatFailsShowsTheMountedRowsAndWhy(_ error: ShareListError, _ reason: String)
    async throws
{
    for viewMode in [ViewMode.list, .column] {
        let world = await World(
            [mountedShare("music")], startError: error == .toolMissing ? error : nil)
        let window = try Window(world, viewMode: viewMode)
        if error != .toolMissing { await world.answer(.failure(error)) }

        _ = try await window.shows(["music"])

        #expect(window.serverPane.state.isServerListed)
        await settle { window.note != nil }
        #expect(window.note == "Couldn't list the shares on “HAL9000”: \(reason)")
        // A row with no message over it: the notice is under the path bar.
        #expect(PaneViewController.message(for: window.serverPane) == nil)
    }
}

/// In column view the notice is the server column's while it has the keys, and goes while a
/// share's column has them.
@MainActor @Test func theNoticeShowsWhileTheServersColumnHasTheKeys() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world, viewMode: .column)
    await world.answer(.failure(.rejected))
    _ = try await window.shows(["music"])
    await settle { window.note != nil }
    let trail = try #require(window.pane.columnTrail)

    window.select(["music"])
    trail.openHeldColumn()
    await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
    trail.focus(trail.columns[1])
    await settle { window.note == nil }

    trail.focus(trail.columns[0])
    await settle { window.note != nil }
    #expect(
        window.note == "Couldn't list the shares on “HAL9000”: The server rejected the password.")
}

@MainActor @Test func anAFPServerListsItsMountedSharesAndSaysSo() async throws {
    let world = await World([mountedShare("music", fsType: "afpfs")])
    let window = try Window(world)

    _ = try await window.shows(["music"])

    await settle { window.note != nil }
    #expect(window.note == "Only mounted shares are listed for AFP servers.")
    #expect(world.enumerator.starts.isEmpty)
}

@MainActor @Test func aMountedShareWhoseSourceDoesntDecodeIsntMatched() async throws {
    let world = await World([mountedShare("music"), mountedShare("bad%zz")])
    let window = try Window(world)

    _ = try await window.shows(["bad%zz", "music"])

    await settle { window.note != nil }
    #expect(window.note == "Couldn't match the shares mounted from “HAL9000”.")
    #expect(world.enumerator.starts.isEmpty)
}

/// A server chooses its shares' names: one no row can have is left out, whether the list left
/// it out or not, and the notice says so (docs/decisions/0115-server-shares.md).
@MainActor @Test func sharesWhoseNamesCantBeRowsAreLeftOutWithANotice() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    await world.answer(
        .success(ShareList(names: ["main", "a/b", "..", "x\u{202E}y", "music"], unusableCount: 1)))

    _ = try await window.shows(["main", "music"])

    #expect(window.pane.state.isServerListed)
    await settle { window.note != nil }
    #expect(window.note == "Some shares on “HAL9000” have names that can't be shown.")
}

// MARK: Showing and refreshing

/// Back at a server whose list is cached, past its lifetime, the cached rows show at once and
/// the new list replaces them.
@MainActor @Test func aCachedListShowsWhileTheServerIsListedAgain() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    await world.answer(.success(["main", "music"]))
    _ = try await window.shows(["main", "music"])
    window.pane.navigate(to: Location(path: "/Volumes/music"))
    await settle { window.pane.state.isLoaded }
    world.clock.advance(by: ServerShares.namesLifetime + .seconds(1))

    window.pane.goBack()

    await settle {
        if case .cachedRefreshing = window.pane.state { true } else { false }
    }
    #expect(window.pane.state.names == ["main", "music"])
    await world.answer(.success(["docker", "main", "music"]), start: 2)
    await settle { window.pane.state.names == ["docker", "main", "music"] }
    #expect(window.pane.state.isLoaded)
}

@MainActor @Test func aListThatDoesntComeShowsSlowAtThreeSecondsOnTheClock() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    #expect(await world.enumerator.waitForStarts(1))
    // The list's give-up and the load's slow wait.
    await settle { world.clock.waitingSleeps >= 2 }
    #expect(window.pane.state.listing == nil)

    world.clock.advance(by: LoadTimeouts.slow)

    await settle { if case .slow = window.pane.state { true } else { false } }
    await settle { window.note == "HAL9000 is slow to answer." }
    await world.answer(.success(["main", "music"]))
    await settle { window.pane.state.isLoaded }
    #expect(window.note == nil)
}

@MainActor @Test func aTableChangeWithinTheListsLifetimeStartsNoList() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    await world.answer(.success(["main", "music"]))
    _ = try await window.shows(["main", "music"])

    await world.remount([mountedShare("music"), mountedShare("video")])
    await settle { window.pane.state.names == ["main", "music", "video"] }
    #expect(world.enumerator.starts.count == 1)

    world.clock.advance(by: ServerShares.namesLifetime)
    await world.remount([mountedShare("music")])
    await world.answer(.success(["main", "music", "photos"]), start: 2)
    await settle { window.pane.state.names == ["main", "music", "photos"] }
}

/// The app becoming active lists a server again, and runs the list only past its lifetime.
@MainActor @Test func relistingServersAsksForAListOnlyPastItsLifetime() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    await world.answer(.success(["main", "music"]))
    _ = try await window.shows(["main", "music"])
    let version = window.pane.stateVersion

    world.shares.relistServers()
    await settle { window.pane.stateVersion > version && window.pane.state.isLoaded }
    #expect(world.enumerator.starts.count == 1)

    world.clock.advance(by: ServerShares.namesLifetime)
    world.shares.relistServers()
    await world.answer(.success(["main", "music", "photos"]), start: 2)
    await settle { window.pane.state.names == ["main", "music", "photos"] }
}

@MainActor @Test func leavingTheServerEndsTheListItWaitsFor() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    #expect(await world.enumerator.waitForStarts(1))

    window.pane.navigate(to: Location(path: "/Volumes/music"))

    await settle { world.enumerator.terminations == 1 }
}

@MainActor @Test func backToAServerThatLostItsSharesForgetsItsList() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world)
    await world.answer(.success(["main", "music"]))
    _ = try await window.shows(["main", "music"])
    window.pane.navigate(to: Location(path: "/Volumes/main"))
    await settle { window.pane.state.isLoaded }
    #expect(world.shares.cachedNames(for: dylans) != nil)

    await world.remount([])
    window.pane.goBack()

    await settle { if case .notConnected = window.pane.state { true } else { false } }
    #expect(world.shares.cachedNames(for: dylans) == nil)
}

// MARK: Refusals

/// The commands a selection with a share that isn't mounted turns off: each acts on the
/// selected items, or in column view on the selected folder's column, which such a share has
/// none of.
private let refusedCommands: [CommandID] = [
    NavigationCommands.open.id, NavigationCommands.showPackageContents.id,
    DualPaneCommands.openInOtherPane.id,
    SystemCommands.getInfo.id, SystemCommands.copyPath.id, SystemCommands.revealInFinder.id,
    SystemCommands.openTerminal.id,
    FileCommands.rename.id, FileCommands.duplicate.id, FileCommands.moveToTrash.id,
    FileCommands.copyToOtherPane.id, FileCommands.moveToOtherPane.id, FileCommands.newFolder.id,
    ClipboardCommands.copy.id, ClipboardCommands.cut.id, ClipboardCommands.paste.id,
    ClipboardCommands.moveHere.id,
]

/// HAL9000's "main" isn't mounted, and another server's "main" is at /Volumes/main. The row is
/// no way into the other server's share: a drop on it is refused and copies nothing, it drags
/// nothing, and every command on a selection holding it is off, in both views.
@MainActor @Test(arguments: [ViewMode.list, .column])
func anUnmountedShareBesideAnotherServersShareOfItsNameRefusesEverything(_ viewMode: ViewMode)
    async throws
{
    let world = await World([mountedShare("main", of: "192.168.1.5"), mountedShare("music")])
    let window = try Window(world, viewMode: viewMode)
    await world.answer(.success(["main", "music"]))
    let list = try await window.shows(["main", "music"])
    #expect(window.serverPane.state.types["main"] == .unmountedShare)
    let main = try #require(window.serverPane.state.listing?.row(named: "main"))
    let table = list.tableView
    // Music shows what is on for a share that is mounted.
    window.select(["music"])
    #expect(table.canRunCommand(ClipboardCommands.copy.id))
    #expect(table.canRunCommand(SystemCommands.getInfo.id))
    #expect(table.canRunCommand(NavigationCommands.open.id))

    // A drop of a file on the row.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    let item = NSPasteboardItem()
    item.setString(URL(fileURLWithPath: "/Users/someone/a.txt").absoluteString, forType: .fileURL)
    #expect(pasteboard.writeObjects([item]))
    let info = StubDraggingInfo(pasteboard: pasteboard)
    #expect(
        list.tableView(table, validateDrop: info, proposedRow: main, proposedDropOperation: .on)
            == [])
    #expect(!list.tableView(table, acceptDrop: info, row: main, dropOperation: .on))
    #expect(list.tableView(table, pasteboardWriterForRow: main) == nil)
    // A drag hovering over the row springs nothing open.
    window.select(["main"])
    window.serverPane.springOpen("main")
    #expect(window.pane.location == .server(testServer))
    #expect((window.pane.columnTrail?.columns.count ?? 1) == 1)
    let music = try #require(window.serverPane.state.listing?.row(named: "music"))
    window.select(["music"])
    #expect(list.tableView(table, pasteboardWriterForRow: music) != nil)

    for names in [["main"], ["main", "music"]] {
        window.select(names)
        #expect(window.serverPane.selectsUnmountedShare)
        // A drag of the selection carries none of it, the mounted share included.
        for row in names.map({ $0 == "main" ? main : music }) {
            #expect(list.tableView(table, pasteboardWriterForRow: row) == nil, "\(names)")
        }
        let on = refusedCommands.filter { table.canRunCommand($0) }
        #expect(on.isEmpty, "\(names): \(on)")
        // A key runs its command whatever its item says: Copy leaves the clipboard as it was.
        table.runCommand(ClipboardCommands.copy.id)
        #expect(window.clipboard.clipboard.fileURLs().isEmpty)
        #expect(!list.writeSelection(to: pasteboard, types: [.fileURL]))
        #expect(list.validRequestor(forSendType: .fileURL, returnType: nil) as? NSObject !== list)
        #expect(OpenWith.types(in: window.serverPane).isEmpty)
        var beeps = 0
        var opened = false
        table.beep = { beeps += 1 }
        list.quickLook.isPanelOpen = { false }
        list.quickLook.openPanel = { opened = true }
        list.quickLook.toggle()
        #expect(beeps == 1 && !opened)

        // The menu is Open, off.
        let menu = list.contextMenu(forRow: main)
        #expect(menu.items.map(\.title) == ["Open"])
        let open = try #require(menu.items.first)
        #expect((open.target as? NSMenuItemValidation)?.validateMenuItem(open) == false)
    }
}

/// HAL9000's "main" was ejected and another server's "main" mounted at /Volumes/main. Until the
/// server lists again its "main" is still a folder row, which resolves to nothing: a selection
/// holding it turns every command off, as an unmounted share's does, and Copy leaves the
/// clipboard as it was rather than empty it. The checks run in an observer of the table's
/// read, after the pane's, which has only started the listing that changes the row.
@MainActor @Test func aRowWhoseShareWentRefusesTheWholeSelection() async throws {
    let world = await World([mountedShare("main"), mountedShare("music")])
    let window = try Window(world)
    await world.answer(.success(["main", "music"]))
    let list = try await window.shows(["main", "music"])
    let table = list.tableView
    let kept = URL(fileURLWithPath: "/Users/someone/kept.txt")
    window.clipboard.copy([kept])
    let services = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
    defer { services.releaseGlobally() }

    var checked: [[String]: (on: [CommandID], clipboard: [URL], services: Bool)] = [:]
    let observer = NSObject()
    world.table.observe(for: observer) {
        guard window.pane.state.types["main"] == .directory else { return }
        for names in [["main"], ["main", "music"]] {
            window.select(names)
            table.runCommand(ClipboardCommands.copy.id)
            checked[names] = (
                refusedCommands.filter { table.canRunCommand($0) },
                window.clipboard.clipboard.fileURLs(),
                list.writeSelection(to: services, types: [.fileURL])
            )
        }
    }
    world.mounts.set([mountedShare("main", of: "192.168.1.5"), mountedShare("music")])
    world.table.refresh()
    await settle { checked.count == 2 }

    for (names, result) in checked {
        #expect(result.on.isEmpty, "\(names): \(result.on)")
        #expect(result.clipboard == [kept], "\(names)")
        #expect(!result.services, "\(names)")
    }
    withExtendedLifetime(observer) {}
}

/// In column view a share with no location opens nothing, by a selection, →, Open, ⌘↓,
/// Return or a spring: no column, no preview, the keys stay in the server's column and the pane
/// stays at the server. Both a share that isn't mounted and one ejected since the server listed
/// it, checked in an observer of the table's read before the server lists again.
@MainActor @Test func inColumnViewAShareWithNoLocationOpensNothing() async throws {
    let world = await World([mountedShare("music"), mountedShare("video")])
    let window = try Window(world, viewMode: .column)
    await world.answer(.success(["main", "music", "video"]))
    let list = try await window.shows(["main", "music", "video"])
    let trail = try #require(window.pane.columnTrail)
    let table = list.tableView
    table.beep = {}
    let cmdDown = try keyEvent(
        functionKey(NSDownArrowFunctionKey), modifiers: [.command, .numericPad, .function])
    let returnKey = try keyEvent("\r")

    /// What went wrong when `name` was tried, empty when nothing opened.
    func tryOpening(_ name: String) -> [String] {
        var wrong: [String] = []
        func check(_ step: String) {
            if trail.columns.count != 1 { wrong.append("\(step): \(trail.columns.count) columns") }
            if trail.focusedIndex != 0 { wrong.append("\(step): focus at \(trail.focusedIndex)") }
            if trail.shownPreview != nil { wrong.append("\(step): a preview") }
            if window.pane.location != .server(testServer) { wrong.append("\(step): navigated") }
        }
        window.select([name])
        check("select")
        trail.moveRight()
        check("→")
        table.runCommand(NavigationCommands.open.id)
        check("Open")
        table.keyDown(with: cmdDown)
        check("⌘↓")
        table.keyDown(with: returnKey)
        check("Return")
        window.serverPane.springOpen(name)
        check("spring")
        if !window.systemActions.openedFiles.isEmpty { wrong.append("opened a file") }
        return wrong
    }

    #expect(window.serverPane.state.types["main"] == .unmountedShare)
    #expect(tryOpening("main") == [])

    var stale: [String]?
    let observer = NSObject()
    world.table.observe(for: observer) {
        guard window.serverPane.state.types["video"] == .directory else { return }
        stale = tryOpening("video")
    }
    world.mounts.set([mountedShare("music")])
    world.table.refresh()
    await settle { stale != nil }
    #expect(stale == [])
    withExtendedLifetime(observer) {}
}

/// A server whose list failed shows its mounted shares as `serverListed`, not a complete
/// listing. Ejecting the share whose column is open drops its row, and the column with it: a
/// server's rows are the mount table's, so a row that went is gone.
@MainActor @Test func ejectingTheShareWhoseColumnIsOpenClosesItsColumn() async throws {
    let world = await World([mountedShare("music"), mountedShare("video")])
    let window = try Window(world, viewMode: .column)
    await world.answer(.failure(.rejected))
    _ = try await window.shows(["music", "video"])
    #expect(window.serverPane.state.isServerListed)
    let trail = try #require(window.pane.columnTrail)
    window.select(["music"])
    await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }

    await world.remount([mountedShare("video")])

    await settle { window.serverPane.state.names == ["video"] }
    await settle { trail.columns.count == 1 }
    #expect(trail.columns.map(\.pane.location) == [.server(testServer)])
}
