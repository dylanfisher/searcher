import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

// A pane at a server lists the server's shares from the app's mount table, asking no share,
// and lists them again when the table reads a change (docs/decisions/0114-server-location.md).

@MainActor @Test func aServerListsItsSharesFromTheMountTableAndNoOtherVolume() async {
    let mounts = StubMounts([
        VolumeIdentity(device: "/dev/disk3s1", mountPoint: "/", kind: .local),
        mountedShare("music"),
        mountedShare("photos", of: "192.168.1.5"),
        VolumeIdentity(device: "/dev/disk4s1", mountPoint: "/Volumes/Backup", kind: .local),
        // The same share mounted twice, the second at "main 1", as the system names it.
        mountedShare("main"),
        VolumeIdentity(
            device: "//guest@hal9000._smb._tcp.local/main", mountPoint: "/Volumes/main 1",
            kind: .network),
        // Outside /Volumes, so it keeps a sidebar row of its own and isn't the server's.
        VolumeIdentity(
            device: "//dylan@\(testServerHost)/video", mountPoint: "/Users/dylan/video",
            kind: .network),
    ])
    let fixture = await PaneFixture.atServer(mounts: mounts)

    #expect(fixture.pane.state.names == ["main", "main 1", "music"])
    let listing = fixture.pane.state.listing
    #expect(
        listing.map { listing in
            (0..<listing.count).allSatisfy {
                listing[$0].type == .directory
                    && listing[$0].modified == Date(timeIntervalSince1970: 0)
            }
        } == true)
    // Not a folder of any share was read.
    #expect(fixture.lister.calls.isEmpty)
    #expect(await fixture.pane.service.runningLoadCount() == 0)
}

@MainActor @Test func aServerListsAgainWhenTheMountTableReadsAChangeAndNotOtherwise() async throws {
    let mounts = StubMounts([mountedShare("main"), mountedShare("music")])
    let fixture = await PaneFixture.atServer(mounts: mounts)
    let table = try #require(fixture.pane.service.mounts)
    let load = fixture.pane.load

    let landed = table.readsLanded
    table.refresh()
    await settle { table.readsLanded > landed }
    #expect(fixture.pane.load === load)

    mounts.set([mountedShare("main"), mountedShare("music"), mountedShare("video")])
    table.refresh()
    await settle { fixture.pane.state.names == ["main", "music", "video"] }
    #expect(fixture.pane.load !== load)
}

@MainActor @Test func aServerWithNoShareIsNotConnectedUntilAReadHoldsOne() async throws {
    let mounts = StubMounts([mountedShare("photos", of: "192.168.1.5")])
    let fixture = await PaneFixture.atServer(mounts: mounts)
    #expect(fixture.pane.state.isNotConnected)
    #expect(fixture.pane.state.listing == nil)

    mounts.set([mountedShare("photos", of: "192.168.1.5"), mountedShare("music")])
    try #require(fixture.pane.service.mounts).refresh()
    await settle { fixture.pane.state.names == ["music"] }

    // Its last share ejected, it isn't connected again.
    mounts.set([])
    try #require(fixture.pane.service.mounts).refresh()
    await settle { fixture.pane.state.isNotConnected }
}

@MainActor @Test func backToAServerThatLostItsSharesShowsItNotConnected() async throws {
    let mounts = StubMounts([mountedShare("main"), mountedShare("music")])
    let fixture = await PaneFixture.atServer(
        folders: ["/Volumes/music": [file("song.mp3")]], mounts: mounts)
    fixture.select("music")
    fixture.pane.openSelection()
    await settle { fixture.pane.state.names == ["song.mp3"] }
    #expect(fixture.pane.location == Location(path: "/Volumes/music"))

    mounts.set([])
    let table = try #require(fixture.pane.service.mounts)
    let landed = table.readsLanded
    table.refresh()
    await settle { table.readsLanded > landed }
    fixture.pane.goBack()

    #expect(fixture.pane.location == .server(testServer))
    await settle { fixture.pane.state.isNotConnected }
}

@MainActor @Test func aServerPaneWalksNoShareAndCalculatesNoSizes() async {
    let fixture = await PaneFixture.atServer()
    fixture.pane.settings.folderSizes = true
    // Walks nothing real: a walk of a share would read the whole share.
    fixture.pane.folderSizes = FolderSizeService(
        cache: FolderSizeCache(store: nil), log: { _ in },
        walk: { path, _ in
            Issue.record("walked \(path)")
            throw CancellationError()
        },
        volumeOf: { _ in ListingService.listerVolume }, mountedVolumes: { [] })

    #expect(!fixture.pane.canCalculateSizes)
    #expect(!fixture.pane.showsFolderSizes)
    #expect(!fixture.pane.awaitsFolderSizes)
    // Does nothing, where a folder's would drop and walk its sizes.
    fixture.pane.calculateSizes()
    #expect(fixture.pane.state.names == ["main", "music"])
}

@MainActor @Test func aServerPaneKeepsNoRecentListingAndFocusListsNothing() async {
    let recent = RecentListings()
    let table = StubMounts([mountedShare("music")]).table()
    let pane = Pane(
        location: .server(testServer),
        service: ListingService(lister: StubLister([:]), recentListings: recent, mounts: table),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    await settle { pane.state.isLoaded }
    let load = pane.load

    pane.didGainFocus()

    #expect(pane.load === load)
    #expect(recent.listing(at: "/Volumes") == nil)
}

/// A server's rows are its shares' mount points, so a share cut in a pane at /Volumes dims
/// there too, and nothing outside /Volumes does.
@MainActor @Test func aServersCutNamesAreItsSharesMountPointsCut() {
    let cut = CutState(clipboard: MemoryClipboard())
    cut.cut([
        URL(fileURLWithPath: "/Volumes/music", isDirectory: true),
        URL(fileURLWithPath: "/Users/someone/a.txt", isDirectory: false),
    ])

    #expect(cut.cutNames(in: .server(testServer)) == ["music"])
}
