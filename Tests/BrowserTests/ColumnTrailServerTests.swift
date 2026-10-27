import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

// In column view a folder in a server's share has the server's column left of the share's,
// and a pane at the server shows that column alone; the path bar and Enclosing Folder go up to
// the server (docs/decisions/0114-server-location.md).

/// HAL9000's shares `main` and `music`, mounted in /Volumes; `music` holds folders `a` and `b`
/// and a file `m.txt`.
private let shares: [String: [DirectoryEntry]] = [
    "/": [folder("Volumes")],
    "/Volumes": [folder("main"), folder("music")],
    "/Volumes/main": [file("n.txt")],
    "/Volumes/music": [folder("a"), folder("b"), file("m.txt")],
    "/Volumes/music/a": [file("x.txt")],
    "/Volumes/music/b": [file("y.txt")],
]

/// Both of HAL9000's shares.
private func bothShares() -> StubMounts {
    StubMounts([mountedShare("main"), mountedShare("music")])
}

/// A pane at `path` over `shares` in `viewMode`, its mount table reading `mounts`, read before
/// the pane is made, and every column listed.
@MainActor
private func sharePane(
    at path: String, mounts: StubMounts = bothShares(), viewMode: ViewMode = .column
) async -> PaneFixture {
    let table = mounts.table()
    await table.firstRead()
    let fixture = PaneFixture(at: path, folders: shares, mounts: table, viewMode: viewMode)
    await settle { listed(fixture.pane) }
    return fixture
}

/// A pane at HAL9000 over `shares`, switched to columns once it lists the shares.
@MainActor
private func serverColumnPane(mounts: StubMounts = bothShares()) async -> PaneFixture {
    let fixture = await PaneFixture.atServer(folders: shares, mounts: mounts)
    fixture.pane.setViewMode(.column)
    await settle { listed(fixture.pane) }
    return fixture
}

/// Whether the pane, or each of its columns, shows its listing.
@MainActor
private func listed(_ pane: Pane) -> Bool {
    guard let trail = pane.columnTrail else { return pane.state.isLoaded }
    return trail.columns.allSatisfy { $0.pane.state.isLoaded }
}

@MainActor
private func trail(_ pane: Pane) -> ColumnTrail {
    guard let trail = pane.columnTrail else {
        preconditionFailure("the pane isn't in column mode")
    }
    return trail
}

/// Each column's folder, or a server column's server name.
@MainActor
private func places(_ pane: Pane) -> [String] {
    trail(pane).columns.map { $0.pane.location.path ?? $0.pane.location.name }
}

/// Runs the command bound to `chord` on the pane keys act on, as the view does.
@MainActor
private func press(_ chord: KeyChord, on pane: Pane) throws {
    let registry = try AppCommands.registry()
    let command = try #require(registry.command(for: chord), "nothing is bound to \(chord)")
    let binding = try #require(AppCommands.bindings.first { $0.command == command })
    binding.run(CommandContext(pane: pane.commandPane))
}

private let commandUp = KeyChord(.up, modifiers: .command)

// MARK: The server column

@MainActor @Test func aShareFoldersTrailHasTheServerColumnOnItsFirstFrame() async {
    let table = bothShares().table()
    await table.firstRead()

    let fixture = PaneFixture(
        at: "/Volumes/music/a", folders: shares, mounts: table, viewMode: .column)
    let pane = fixture.pane

    #expect(places(pane) == ["HAL9000", "/Volumes/music", "/Volumes/music/a"])
    #expect(trail(pane).serverRoot == testServer)
    #expect(trail(pane).focusedIndex == 2)
    #expect(pane.location == Location(path: "/Volumes/music/a"))
    await settle { listed(pane) }
    #expect(trail(pane).columns[0].pane.state.names == ["main", "music"])
    #expect(trail(pane).columns.map { $0.pane.selection.cursor?.name } == ["music", "a", nil])
    // The root check finds the share's mount point, as the path has it.
    await trail(pane).rootChecked()
    #expect(places(pane) == ["HAL9000", "/Volumes/music", "/Volumes/music/a"])
}

/// Built before the mount table's first read, the trail has no server column; the read adds
/// it on the left, the keys staying in their column.
@MainActor @Test func theMountTablesFirstReadAddsTheServerColumn() async {
    let table = bothShares().table()
    let fixture = PaneFixture(
        at: "/Volumes/music/a", folders: shares, mounts: table, viewMode: .column)
    let pane = fixture.pane
    #expect(places(pane) == ["/Volumes/music", "/Volumes/music/a"])
    let focused = trail(pane).focused.pane
    var changes = 0
    pane.onChange = { changes += 1 }

    await table.firstRead()

    #expect(places(pane) == ["HAL9000", "/Volumes/music", "/Volumes/music/a"])
    #expect(trail(pane).focused.pane === focused)
    #expect(trail(pane).focusedIndex == 2)
    #expect(changes > 0)
    await settle { listed(pane) }
    #expect(trail(pane).columns[0].pane.selection.cursor == ExactName("music"))
    #expect(places(pane) == ["HAL9000", "/Volumes/music", "/Volumes/music/a"])
}

/// A share mounted after its trail was built adds the server column once the table reads it;
/// the server's last share going leaves the column, saying the server isn't connected.
@MainActor @Test func aShareMountedLaterAddsTheServerColumnAndItsUnmountKeepsIt() async throws {
    let mounts = StubMounts([mountedShare("main")])
    let fixture = await sharePane(at: "/Volumes/music/a", mounts: mounts)
    let pane = fixture.pane
    #expect(places(pane) == ["/Volumes/music", "/Volumes/music/a"])
    let table = try #require(pane.service.mounts)

    mounts.set([mountedShare("main"), mountedShare("music")])
    table.refresh()
    await settle { places(pane).count == 3 }
    await settle { listed(pane) }
    #expect(trail(pane).focusedIndex == 2)

    mounts.set([])
    table.refresh()
    await settle { trail(pane).columns[0].pane.state.isNotConnected }
    #expect(places(pane) == ["HAL9000", "/Volumes/music", "/Volumes/music/a"])
}

/// A pane at a server in column view shows the server's column alone, the keys in it; a share
/// selected there opens its column, and ← there does nothing, as at any root.
@MainActor @Test func aPaneAtAServerShowsItsColumnAlone() async throws {
    let fixture = await serverColumnPane()
    let pane = fixture.pane

    #expect(places(pane) == ["HAL9000"])
    #expect(trail(pane).serverRoot == testServer)
    #expect(trail(pane).focusedIndex == 0)
    #expect(trail(pane).focused.pane.state.names == ["main", "music"])

    trail(pane).focused.pane.select(Selection([ExactName("music")], cursor: ExactName("music")))
    await settle { places(pane) == ["HAL9000", "/Volumes/music"] }
    #expect(pane.location == .server(testServer))
    try press(KeyChord(.left), on: pane)
    #expect(trail(pane).focusedIndex == 0)

    try press(KeyChord(.right), on: pane)
    #expect(pane.location == Location(path: "/Volumes/music"))
    #expect(trail(pane).focusedIndex == 1)
}

/// A navigation to the server, as the sidebar's server row makes, keeps the server column of a
/// trail in one of its shares, so it lists nothing again; a navigation to another share of it
/// keeps it too.
@MainActor @Test func aNavigationWithinOneServerKeepsItsColumn() async throws {
    let fixture = await sharePane(at: "/Volumes/music/a")
    let pane = fixture.pane
    let server = trail(pane).columns[0].pane
    let load = server.load

    pane.navigate(to: Location(path: "/Volumes/main"))
    #expect(places(pane) == ["HAL9000", "/Volumes/main"])
    #expect(trail(pane).columns[0].pane === server)
    #expect(server.selection.cursor == ExactName("main"))

    pane.navigate(to: .server(testServer))
    #expect(places(pane) == ["HAL9000"])
    #expect(trail(pane).columns[0].pane === server)
    #expect(trail(pane).focusedIndex == 0)
    #expect(pane.location == .server(testServer))
    #expect(server.load === load)

    // A folder on no server's share has no server column.
    pane.navigate(to: Location(path: "/Volumes"))
    #expect(places(pane) == ["/", "/Volumes"])
    #expect(trail(pane).serverRoot == nil)
}

// MARK: Enclosing Folder

/// ⌘↑ at a share's root shows the server with the share selected; at the server it does
/// nothing, in column view and in the list.
@MainActor @Test func commandUpAtAShareRootShowsTheServerAndAtTheServerDoesNothing() async throws {
    let columns = await sharePane(at: "/Volumes/music")
    let pane = columns.pane
    #expect(trail(pane).focusedIndex == 1)

    try press(commandUp, on: pane)

    #expect(pane.location == .server(testServer))
    #expect(trail(pane).focusedIndex == 0)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("music"))
    #expect(places(pane) == ["HAL9000", "/Volumes/music"])
    try press(commandUp, on: pane)
    #expect(trail(pane).focusedIndex == 0)
    #expect(places(pane) == ["HAL9000", "/Volumes/music"])

    let list = await sharePane(at: "/Volumes/music", viewMode: .list)
    try press(commandUp, on: list.pane)
    #expect(list.pane.location == .server(testServer))
    await settle { list.pane.state.isLoaded && list.pane.selection.isSettled }
    #expect(list.pane.selection == Selection([ExactName("music")], cursor: ExactName("music")))
    #expect(list.pane.canGoBack)
    list.pane.goBack()
    #expect(list.pane.location == Location(path: "/Volumes/music"))
    list.pane.navigate(to: .server(testServer))
    try press(commandUp, on: list.pane)
    #expect(list.pane.location == .server(testServer))
}

// MARK: Ancestors and the path bar

/// A folder in a share has the server, then the folders from the share down; a disk's folder
/// keeps the path from `/`, and so does a share's before the table is read.
@MainActor @Test func aShareFoldersAncestorsStartAtItsServer() async {
    let backup = VolumeIdentity(device: "/dev/disk5s1", mountPoint: "/Volumes/Backup", kind: .local)
    let table = StubMounts([mountedShare("music"), backup]).table()
    let unread = PaneFixture(
        at: "/Volumes/music/a", folders: shares.merging(["/Volumes/Backup/x": []]) { $1 },
        mounts: table)
    #expect(unread.pane.ancestors == Location(path: "/Volumes/music/a").ancestors)
    await table.firstRead()
    func ancestors(_ location: Location) -> [Location] {
        let pane = Pane(
            location: location, service: unread.pane.service,
            systemActions: StubSystemActions(), settings: untouchedSettings())
        return pane.ancestors
    }

    #expect(
        ancestors(Location(path: "/Volumes/music/a")) == [
            .server(testServer), Location(path: "/Volumes/music"),
            Location(path: "/Volumes/music/a"),
        ])
    #expect(
        ancestors(Location(path: "/Volumes/music")) == [
            .server(testServer), Location(path: "/Volumes/music"),
        ])
    #expect(
        ancestors(Location(path: "/Volumes/Backup/x"))
            == Location(path: "/Volumes/Backup/x").ancestors)
    #expect(ancestors(.server(testServer)) == [.server(testServer)])
}

/// A path bar click on the server shows it with the share as the cursor: in column view its
/// column takes the keys and is the last, as for any folder above (0103); in the list the pane
/// goes to the server, selecting the share.
@MainActor @Test func aPathBarClickOnTheServerShowsItComingFromTheShare() async throws {
    let columns = await sharePane(at: "/Volumes/music/a")
    let pane = columns.pane

    pane.showFolderAbove(.server(testServer), comingFrom: "music")

    #expect(pane.location == .server(testServer))
    #expect(places(pane) == ["HAL9000"])
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("music"))
    #expect(pane.canGoBack)

    let list = await sharePane(at: "/Volumes/music/a", viewMode: .list)
    list.pane.showFolderAbove(.server(testServer), comingFrom: "music")
    #expect(list.pane.location == .server(testServer))
    await settle { list.pane.state.isLoaded && list.pane.selection.isSettled }
    #expect(list.pane.selection == Selection([ExactName("music")], cursor: ExactName("music")))
}

// MARK: History

/// Back from a share to its server, both shown by one trail, gives the keys to the server's
/// column with the share selected, and Forward goes back into the share; Back across trails
/// starts the trail again at the server.
@MainActor @Test func backAndForwardCrossBetweenTheServerAndAShare() async throws {
    let fixture = await serverColumnPane()
    let pane = fixture.pane
    trail(pane).focused.pane.select(Selection([ExactName("music")], cursor: ExactName("music")))
    await settle { listed(pane) && places(pane).count == 2 }
    try press(KeyChord(.right), on: pane)
    #expect(pane.location == Location(path: "/Volumes/music"))

    pane.goBack()
    #expect(pane.location == .server(testServer))
    #expect(trail(pane).focusedIndex == 0)
    #expect(trail(pane).focused.pane.selection.cursor == ExactName("music"))
    #expect(places(pane) == ["HAL9000", "/Volumes/music"])

    pane.goForward()
    #expect(pane.location == Location(path: "/Volumes/music"))
    #expect(trail(pane).focusedIndex == 1)

    pane.navigate(to: Location(path: "/"))
    #expect(trail(pane).serverRoot == nil)
    pane.goBack()
    #expect(pane.location == Location(path: "/Volumes/music"))
    #expect(places(pane) == ["HAL9000", "/Volumes/music"])
    pane.goBack()
    #expect(pane.location == .server(testServer))
    #expect(trail(pane).focusedIndex == 0)
}

/// ⌘U to a step in the server column, after the server lost its shares, puts the keys back in
/// the column, which says the server isn't connected. With no rows to resolve them against,
/// its steps are kept by name, and the rows that list the server again drop the names they
/// don't have, as any listing does (0077-selection-history.md).
@MainActor @Test func undoSelectionToTheServerColumnAfterItsSharesWent() async throws {
    let mounts = bothShares()
    let fixture = await serverColumnPane(mounts: mounts)
    let pane = fixture.pane
    let server = trail(pane).focused.pane
    server.select(Selection([ExactName("main")], cursor: ExactName("main")))
    server.select(Selection([ExactName("music")], cursor: ExactName("music")))
    await settle { places(pane).count == 2 && listed(pane) }
    try press(KeyChord(.right), on: pane)
    #expect(trail(pane).focusedIndex == 1)
    mounts.set([])
    try #require(pane.service.mounts).refresh()
    await settle { server.state.isNotConnected }

    fixture.tab.undoSelection()

    #expect(trail(pane).focusedIndex == 0)
    #expect(pane.location == .server(testServer))
    #expect(server.state.isNotConnected)
    #expect(server.selection.cursor == ExactName("music"))
    fixture.tab.undoSelection()
    #expect(server.selection.cursor == ExactName("main"))
    #expect(trail(pane).focusedIndex == 0)

    mounts.set([mountedShare("music")])
    try #require(pane.service.mounts).refresh()
    await settle { server.state.names == ["music"] }
    #expect(server.selection.isEmpty)
    #expect(server.selection.cursor == nil)
    #expect(places(pane) == ["HAL9000"])
}
