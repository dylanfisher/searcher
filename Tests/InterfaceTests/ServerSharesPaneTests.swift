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
// isn't mounted takes no drop, drags nothing and turns off every command on the selection but
// Open, which mounts it, selected alone, and goes into it (docs/decisions/0115-server-shares.md).
// Each test goes through the real listing service, panes, views and mount table; the mounts,
// `smbutil`, NetFS and the clock are stubs.

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
    let mounter = GatedShareMounter()
    let mounts: StubMounts
    let table: MountTable
    let shares: ServerShares
    let shareMounts: ShareMounts
    let service: ListingService

    init(_ volumes: [VolumeIdentity], startError: ShareListError? = nil) async {
        enumerator = GatedShareEnumerator(startError: startError)
        mounts = StubMounts(volumes)
        table = mounts.table()
        await table.firstRead()
        shares = ServerShares(enumerator: enumerator, clock: clock)
        shareMounts = ShareMounts(mounter: mounter, table: table)
        service = ListingService(
            lister: StubLister(folders), clock: clock, mounts: table, shares: shares,
            shareMounts: shareMounts)
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
    /// The list view's table, whose `clickedRow` a test sets for a double-click.
    let listTable: ClickedRowTableView

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
        let listTable = ClickedRowTableView()
        self.listTable = listTable
        var made: PaneViewController?
        controller = BrowserWindowController(
            workspace: Workspace(tab: Tab(pane: pane)), workspaces: WorkspaceList(),
            favorites: Favorites(settings: settings), volumes: volumes, settings: settings,
            fileOperations: FileOperationQueue(prompts: .unexpected) { _ in },
            clipboard: clipboard, mountTable: world.table,
            takePaneController: { _, pane in
                let controller = PaneViewController(
                    pane: pane, iconCache: TypeIconCache { _ in NSImage() }, formatter: .init(),
                    tableView: listTable, monitorsFolders: false)
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

/// The mounted share's row has the eject button, as Finder's column has it on music alone, and
/// it ejects the share through the sidebar's volumes; the unmounted shares have none
/// (docs/decisions/0118-row-eject-buttons.md).
@MainActor @Test(arguments: [ViewMode.list, .column])
func aServersMountedShareRowHasTheEjectButtonAndItsUnmountedOnesNone(_ viewMode: ViewMode)
    async throws
{
    let world = await World([mountedShare("music")])
    let stub = StubSidebarVolumes([
        SidebarVolume(mountPoint: "/Volumes/music", name: "music", kind: .network)
    ])
    let volumes = stub.list()
    await settle { volumes.volumes.count == 1 }
    let window = try Window(world, viewMode: viewMode, volumes: volumes)
    await world.answer(.success(["docker", "main", "music"]))
    let list = try await window.shows(["docker", "main", "music"])
    window.select(["docker"])
    stub.holdEjects()

    #expect(try list.shownEjectButton(atRow: 0) == nil)
    #expect(try list.shownEjectButton(atRow: 1) == nil)
    let eject = try #require(try list.shownEjectButton(atRow: 2))
    #expect(eject.isEnabled)
    eject.performClick(nil)

    await settle { stub.ejects.count == 1 }
    #expect(stub.ejects.map(\.mountPoint) == ["/Volumes/music"])
    await settle { (try? list.shownEjectButton(atRow: 2)?.isEnabled) == false }
    #expect(window.serverPane.selection.cursor == ExactName("docker"))
    stub.releaseEjects()
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
/// nothing, and every command on a selection holding it is off but Open on it alone, which
/// mounts it, in both views.
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
    let pasteboard = testPasteboard()
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
        // Open mounts a share selected alone (docs/decisions/0115-server-shares.md).
        let opens = names == ["main"]
        let on = refusedCommands.filter { table.canRunCommand($0) }
        #expect(on == (opens ? [NavigationCommands.open.id] : []), "\(names): \(on)")
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

        // The menu is Open, on for the share alone.
        let menu = list.contextMenu(forRow: main)
        #expect(menu.items.map(\.title) == ["Open"])
        let open = try #require(menu.items.first)
        #expect((open.target as? NSMenuItemValidation)?.validateMenuItem(open) == opens)
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
    let services = testPasteboard()
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
    let rightKey = try keyEvent(functionKey(NSRightArrowFunctionKey), modifiers: arrowFlags)

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
        table.keyDown(with: rightKey)
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

// MARK: Mounting

private let mainFolder = Location(path: "/Volumes/main")

extension World {
    /// The handle of the `count`th mount started.
    fileprivate func mountStarted(_ count: Int = 1) async throws -> ShareMountHandle {
        #expect(await mounter.waitForStarts(count))
        return try #require(mounter.starts[count - 1].handle)
    }

    /// Mounts HAL9000's "main" at /Volumes/main in the stub table, as the kernel would, and ends
    /// the mount `handle` names with `status` and `mountPoints`.
    fileprivate func mountMain(
        _ handle: ShareMountHandle, status: Int32 = 0,
        mountPoints: [String] = ["/Volumes/main"],
        as main: VolumeIdentity = mountedShare("main")
    ) {
        mounts.set([mountedShare("music"), main])
        #expect(mounter.complete(handle, status: status, mountPoints: mountPoints))
    }
}

/// The alerts a list showed.
@MainActor
private final class Alerts {
    var shown: [(message: String, information: String)] = []

    init(_ list: ListingViewController) {
        list.showAlert = { [weak self] alert in
            self?.shown.append((alert.messageText, alert.informativeText))
        }
    }
}

/// A pane at HAL9000, which lists "main", not mounted, and "music", mounted, with the commands'
/// registry on its rows' table.
@MainActor
private func atServer(_ world: World, viewMode: ViewMode = .list) async throws
    -> (Window, ListingViewController)
{
    let window = try Window(world, viewMode: viewMode)
    // Column view waits out `ColumnTrail.openDelay` on the world's clock.
    window.pane.columnOpenClock = world.clock
    // A second window lists the server from the cache.
    if world.shares.cachedNames(for: dylans) == nil {
        await world.answer(.success(["main", "music"]))
    }
    let list = try await window.shows(["main", "music"])
    list.tableView.beep = {}
    return (window, list)
}

extension Window {
    /// Selects `name` alone as a click on its row does.
    fileprivate func click(_ name: String) throws {
        let listing = try #require(serverPane.state.listing)
        let row = try #require(listing.row(named: name))
        let exact = ExactName(name)
        serverPane.select(rows: IndexSet(integer: row), cursor: exact, anchor: exact)
    }
}

/// Return renames, which a share can't be, so it mounts nothing; Open mounts the share selected
/// alone, and a second Open while it runs starts no other mount. The mount goes into the share.
@MainActor @Test func openMountsTheShareAndASecondOpenStartsNoOther() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    window.select(["main"])

    list.tableView.keyDown(with: try keyEvent("\r"))
    #expect(window.pane.connectingShare == nil)
    #expect(list.tableView.canRunCommand(NavigationCommands.open.id))
    list.tableView.runCommand(NavigationCommands.open.id)
    let handle = try await world.mountStarted()
    #expect(window.pane.connectingShare?.name == "main")
    list.tableView.runCommand(NavigationCommands.open.id)

    #expect(world.mounter.starts.map(\.request) == [ShareMountRequest(share: dylans, name: "main")])
    #expect(world.mounter.starts[0].request.url == "smb://dylan@HAL9000._smb._tcp.local/main")
    world.mountMain(handle)
    await settle { window.pane.location == mainFolder }
    await settle { window.pane.state.isLoaded }
    #expect(window.pane.state.names == ["n.txt"])
    #expect(world.mounter.starts.count == 1)
    #expect(window.pane.connectingShare == nil)
}

/// A double-click on the share's row mounts it in list view, as Open does.
@MainActor @Test func aDoubleClickOnAShareMountsIt() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    window.listTable.row = try #require(window.pane.state.listing?.row(named: "main"))

    let action = try #require(list.tableView.doubleAction)
    #expect(
        NSApplication.shared.sendAction(action, to: list.tableView.target, from: list.tableView))

    #expect(window.pane.selection.members == .only([ExactName("main")]))
    #expect(window.pane.connectingShare?.name == "main")
    world.mountMain(try await world.mountStarted())
    await settle { window.pane.location == mainFolder }
}

/// The server's last SMB share went since its rows were listed: there is no user to mount as,
/// and the sheet says so. Open runs in an observer of the table's read, after the pane's, which
/// has only started the listing that drops the rows.
@MainActor @Test func aShareOfAServerWithNoShareLeftToConnectAsShowsWhy() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    let alerts = Alerts(list)
    window.select(["main"])
    var opened = false
    let observer = NSObject()
    world.table.observe(for: observer) {
        guard world.table.volumes.isEmpty, window.pane.selectedUnmountedShare != nil else {
            return
        }
        list.tableView.runCommand(NavigationCommands.open.id)
        opened = true
    }

    world.mounts.set([])
    world.table.refresh()

    await settle { opened }
    #expect(alerts.shown.map(\.information) == ["No share of “HAL9000” is mounted to connect as."])
    #expect(world.mounter.starts.isEmpty)
    withExtendedLifetime(observer) {}
}

/// Two panes opening one share wait for one mount, which is cancelled only when the last lets
/// go of it (docs/decisions/0115-server-shares.md).
@MainActor @Test func twoPanesShareOneMountCancelledOnlyWithTheLast() async throws {
    let world = await World([mountedShare("music")])
    let (first, firstList) = try await atServer(world)
    let (second, secondList) = try await atServer(world)
    let escape = try keyEvent("\u{1B}")
    for (window, list) in [(first, firstList), (second, secondList)] {
        window.select(["main"])
        list.tableView.runCommand(NavigationCommands.open.id)
    }
    let handle = try await world.mountStarted()
    let request = ShareMountRequest(share: dylans, name: "main")
    await settle { world.shareMounts.askers(of: request) == 2 }

    firstList.tableView.keyDown(with: escape)
    #expect(first.pane.connectingShare == nil)
    await settle { world.shareMounts.askers(of: request) == 1 }
    #expect(world.mounter.cancellations.isEmpty)

    secondList.tableView.keyDown(with: escape)
    await settle { world.mounter.cancellations == [handle] }
    #expect(world.mounter.starts.count == 1)
    // NetFS runs no completion after a cancel.
    #expect(!world.mounter.complete(handle))
}

/// Holding ↓ through seven shares with the clock stopped mounts none of them; the keys stopping
/// on one mounts it once `ColumnTrail.openDelay` passes, as its column would open then.
@MainActor @Test func heldArrowsMountOnlyTheShareTheyStopOn() async throws {
    let world = await World([mountedShare("music")])
    let window = try Window(world, viewMode: .column)
    window.pane.columnOpenClock = world.clock
    let names = ["a", "b", "c", "d", "e", "f", "g", "music"]
    await world.answer(.success(ShareList(names: names)))
    let list = try await window.shows(names)
    let down = try keyEvent(functionKey(NSDownArrowFunctionKey), modifiers: arrowFlags)

    for _ in 0..<7 { list.tableView.keyDown(with: down) }

    #expect(window.serverPane.selection.cursor == ExactName("g"))
    #expect(window.serverPane.connectingShare == nil)
    #expect(world.mounter.starts.isEmpty)
    world.clock.advance(by: ColumnTrail.openDelay)
    await settle { window.serverPane.connectingShare?.name == "g" }
    #expect(await world.mounter.waitForStarts(1))
    #expect(world.mounter.starts.map(\.request.name) == ["g"])
}

/// A click mounts a share in column view at once, where its column would open, and only selects
/// it in list view. → mounts it in column view too, again after a mount that failed.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aClickMountsAShareOnlyInColumnView(_ viewMode: ViewMode) async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world, viewMode: viewMode)

    try window.click("main")

    guard viewMode == .column else {
        #expect(window.pane.connectingShare == nil)
        #expect(world.mounter.starts.isEmpty)
        return
    }
    #expect(window.serverPane.connectingShare?.name == "main")
    let alerts = Alerts(list)
    let handle = try await world.mountStarted()
    #expect(world.mounter.complete(handle, status: EAUTH))
    await settle { !alerts.shown.isEmpty }
    list.tableView.keyDown(
        with: try keyEvent(functionKey(NSRightArrowFunctionKey), modifiers: arrowFlags))
    _ = try await world.mountStarted(2)
}

/// A share mounted from column view opens its column, as a click on a mounted share's row does.
@MainActor @Test func aShareMountedInColumnViewOpensItsColumn() async throws {
    let world = await World([mountedShare("music")])
    let (window, _) = try await atServer(world, viewMode: .column)
    let trail = try #require(window.pane.columnTrail)
    try window.click("main")
    let handle = try await world.mountStarted()

    world.mountMain(handle)

    await settle { trail.columns.count == 2 && trail.columns[1].pane.state.isLoaded }
    #expect(trail.columns.map(\.pane.location) == [.server(testServer), mainFolder])
    #expect(window.serverPane.state.types["main"] == .directory)
    #expect(window.serverPane.connectingShare == nil)
}

/// What lets go of a mount before it ends: the mount is cancelled, and a share that mounts
/// anyway, as the kernel may finish it, is a mounted row and nothing moves. A click on another
/// row lets go of it before the click's selection settles.
enum LettingGo: CaseIterable, Sendable {
    case back, anotherSelection, aClickOnAnotherRow, escape, closingThePane
}

@MainActor @Test(arguments: LettingGo.allCases)
func aMountLetGoOfMovesNothingWhenTheShareMounts(_ how: LettingGo) async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    let music = Location(path: "/Volumes/music")
    if how == .back {
        window.pane.navigate(to: music)
        await settle { window.pane.state.isLoaded }
        window.pane.navigate(to: .server(testServer))
        _ = try await window.shows(["main", "music"])
    }
    window.select(["main"])
    list.tableView.runCommand(NavigationCommands.open.id)
    let handle = try await world.mountStarted()

    switch how {
    case .back: window.pane.goBack()
    case .anotherSelection: window.select(["music"])
    case .aClickOnAnotherRow:
        let row = try #require(window.pane.state.listing?.row(named: "music"))
        list.tableView.selectRowIndexes([row], byExtendingSelection: false)
        #expect(!window.pane.selection.isSettled)
    case .escape: list.tableView.keyDown(with: try keyEvent("\u{1B}"))
    case .closingThePane: window.pane.close()
    }

    #expect(window.pane.connectingShare == nil)
    await settle { world.mounter.cancellations == [handle] }
    #expect(!world.mounter.complete(handle))
    let stays = window.pane.location
    #expect(stays == (how == .back ? music : .server(testServer)))
    await world.remount([mountedShare("music"), mountedShare("main")])
    if how != .back, how != .closingThePane {
        await settle { window.pane.state.types["main"] == .directory }
    }
    #expect(window.pane.location == stays)
}

/// Escape in column view lets go of the mount the server's column waits for, and does only
/// that: the share stays selected and no column changes
/// (docs/decisions/0119-escape-closes-columns.md).
@MainActor @Test func escapeInColumnViewLetsGoOfTheMount() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world, viewMode: .column)
    let trail = try #require(window.pane.columnTrail)
    try window.click("main")
    let handle = try await world.mountStarted()

    list.tableView.keyDown(with: try keyEvent("\u{1B}"))

    #expect(window.serverPane.connectingShare == nil)
    await settle { world.mounter.cancellations == [handle] }
    #expect(trail.columns.map(\.pane.location) == [.server(testServer)])
    #expect(window.serverPane.selection.cursor == ExactName("main"))
    #expect(trail.focusedIndex == 0)
}

/// A mount point the table's read doesn't hold yet moves nothing; the row shows mounted when a
/// read has it, and still nothing moves.
@MainActor @Test func aMountPointTheTableDoesntHoldYetMovesNothing() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    let alerts = Alerts(list)
    window.select(["main"])
    list.tableView.runCommand(NavigationCommands.open.id)
    let handle = try await world.mountStarted()

    #expect(world.mounter.complete(handle, mountPoints: ["/Volumes/main"]))

    await settle { window.pane.connectingShare == nil }
    #expect(window.pane.location == .server(testServer))
    await world.remount([mountedShare("music"), mountedShare("main")])
    await settle { window.pane.state.types["main"] == .directory }
    #expect(window.pane.location == .server(testServer))
    #expect(alerts.shown.isEmpty)
}

/// NetFS runs no completion after a non-zero return: the mount fails at once, with its sheet.
@MainActor @Test func aStartThatFailsAtOnceShowsTheSheet() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    let alerts = Alerts(list)
    world.mounter.failStarts(with: EACCES)
    window.select(["main"])

    list.tableView.runCommand(NavigationCommands.open.id)

    await settle { !alerts.shown.isEmpty }
    #expect(alerts.shown.map(\.message) == ["The share “main” couldn’t be opened."])
    #expect(alerts.shown.map(\.information) == ["Permission denied"])
    #expect(world.mounter.starts.map(\.handle) == [nil])
    #expect(window.pane.connectingShare == nil)
    #expect(window.pane.location == .server(testServer))
}

/// A completion NetFS sends after a cancel, which it never does, answers nobody: not the pane
/// that opened the share again since.
@MainActor @Test func aCompletionAfterACancelIsIgnored() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    let alerts = Alerts(list)
    window.select(["main"])
    list.tableView.runCommand(NavigationCommands.open.id)
    let first = try await world.mountStarted()
    list.tableView.keyDown(with: try keyEvent("\u{1B}"))
    await settle { world.mounter.cancellations == [first] }
    list.tableView.runCommand(NavigationCommands.open.id)
    let second = try await world.mountStarted(2)

    world.mounts.set([mountedShare("music"), mountedShare("main")])
    #expect(world.mounter.complete(first, mountPoints: ["/Volumes/main"], evenIfCancelled: true))
    #expect(world.mounter.complete(second, status: EACCES))

    await settle { !alerts.shown.isEmpty }
    #expect(alerts.shown.map(\.information) == ["Permission denied"])
    #expect(window.pane.location == .server(testServer))
}

/// A share already mounted answers `EEXIST`, here with no mount point: the table's mount of the
/// server's share is gone into.
@MainActor @Test func alreadyMountedWithNoMountPointGoesIntoTheTablesMount() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    window.select(["main"])
    list.tableView.runCommand(NavigationCommands.open.id)

    world.mountMain(try await world.mountStarted(), status: EEXIST, mountPoints: [])

    await settle { window.pane.location == mainFolder }
}

/// A share the system records under another host than the row's server, as a remount by
/// address may be, is still gone into, by the mount point in the result.
@MainActor @Test(arguments: [ViewMode.list, .column])
func aShareMountedUnderAnotherHostIsStillReached(_ viewMode: ViewMode) async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world, viewMode: viewMode)
    try window.click("main")
    if viewMode == .list { list.tableView.runCommand(NavigationCommands.open.id) }

    world.mountMain(try await world.mountStarted(), as: mountedShare("main", of: "192.168.1.5"))

    await settle { window.pane.location == mainFolder }
}

/// The row's spinner and the status "Connecting to “main”…" show only once the mount has taken
/// `LoadTimeouts.spinnerDelay`, and go when it ends.
@MainActor @Test func theSpinnerShowsOnlyAfterTheSpinnerDelay() async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    let table = list.tableView
    let name = try #require(table.tableColumns.first { $0.title == "Name" })
    let row = try #require(window.pane.state.listing?.row(named: "main"))
    func rowSpinnerShows() throws -> Bool {
        let cell = try #require(
            list.tableView(table, viewFor: name, row: row) as? NSTableCellView)
        return !ListingViewController.connectingSpinner(in: cell).isHidden
    }
    window.select(["main"])
    let sleeps = world.clock.waitingSleeps
    table.runCommand(NavigationCommands.open.id)
    let handle = try await world.mountStarted()
    await settle { world.clock.waitingSleeps > sleeps }

    world.clock.advance(by: LoadTimeouts.spinnerDelay - .milliseconds(1))
    #expect(window.pane.connectingShare?.isShown == false)
    #expect(try !rowSpinnerShows())
    #expect(window.note == nil)

    world.clock.advance(by: .milliseconds(1))
    await settle { window.note == "Connecting to “main”…" }
    #expect(try rowSpinnerShows())
    #expect(!window.paneController.status.spinner.isHidden)
    #expect(window.paneController.status.spinner.accessibilityLabel() == "Connecting")

    world.mountMain(handle)
    await settle { window.pane.location == mainFolder && window.note == nil }
}

/// The sheet says why: the system's text for an `errno`, a short text for a NetFS code, and the
/// code for one it doesn't know.
@MainActor
@Test(arguments: [
    (EACCES, "Permission denied"),
    (Int32(-5998), "The server has no shares available to this user."),
    (Int32(-6600), "Error -6600."),
])
func aMountThatFailsShowsWhy(_ status: Int32, _ reason: String) async throws {
    let world = await World([mountedShare("music")])
    let (window, list) = try await atServer(world)
    let alerts = Alerts(list)
    window.select(["main"])
    list.tableView.runCommand(NavigationCommands.open.id)

    #expect(world.mounter.complete(try await world.mountStarted(), status: status))

    await settle { !alerts.shown.isEmpty }
    #expect(alerts.shown.map(\.message) == ["The share “main” couldn’t be opened."])
    #expect(alerts.shown.map(\.information) == [reason])
    #expect(window.pane.location == .server(testServer))
}
