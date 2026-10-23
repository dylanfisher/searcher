import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let share = VolumeIdentity(
    device: "//dylan@nas.invalid/Music", mountPoint: "/fake-mount/Music", kind: .network)

/// Walks that return at once with each path's walk count as its size, so a size walked again
/// reads differently, on a share whose volume read the test can hold or fail.
private final class CountedWalks: @unchecked Sendable {
    private let condition = NSCondition()
    private var counts: [String: Int] = [:]
    private var holdsNextRead = false
    private var readIsHeld = false
    private var failsReads = false
    let log = EventLog<String>()

    func count(_ path: String) -> Int { condition.withLock { counts[path, default: 0] } }

    /// The next volume read waits until `releaseRead`; the ones after it don't.
    func holdNextRead() {
        condition.withLock { holdsNextRead = true }
    }

    func releaseRead() {
        condition.withLock {
            readIsHeld = false
            condition.broadcast()
        }
    }

    func failReads() {
        condition.withLock { failsReads = true }
    }

    func service() -> FolderSizeService {
        FolderSizeService(
            cache: FolderSizeCache(store: nil), log: { self.log.append($0) },
            walk: { path, _ in
                let count = self.condition.withLock {
                    self.counts[path, default: 0] += 1
                    return self.counts[path, default: 0]
                }
                return TreeSizeWalker.Total(bytes: Int64(count), files: count, isPartial: false)
            },
            volumeOf: { path throws(ListingError) in
                let fails = self.condition.withLock {
                    if self.holdsNextRead {
                        self.holdsNextRead = false
                        self.readIsHeld = true
                        while self.readIsHeld { self.condition.wait() }
                    }
                    return self.failsReads
                }
                if fails { throw ListingError(path: path, code: EIO) }
                return share
            })
    }
}

@MainActor
private func binding(_ command: Command) throws -> CommandBinding {
    try #require(AppCommands.bindings.first { $0.command == command })
}

/// A pane at `/music` holding a folder `Albums`, with its size walked once.
@MainActor
private func walkedPane(_ walks: CountedWalks) async -> PaneFixture {
    let fixture = PaneFixture(at: "/music", folders: ["/music": [folder("Albums"), file("song")]])
    fixture.pane.folderSizes = walks.service()
    await settle { albumsSize(fixture.pane) == .size(bytes: 1, isPartial: false) }
    return fixture
}

@MainActor
private func albumsSize(_ pane: Pane) -> Listing.FolderSizeValue? {
    guard let listing = pane.state.listing, let row = listing.row(named: "Albums") else {
        return nil
    }
    return listing.folderSize(atRow: row)
}

@MainActor @Test func recalculateSizesWalksThePanesFoldersAgainPastTheKeptSizes() async throws {
    let walks = CountedWalks()
    let pane = await walkedPane(walks).pane

    try binding(SizeCommands.recalculateSizes).run(CommandContext(pane: pane))

    await settle { albumsSize(pane) == .size(bytes: 2, isPartial: false) }
    #expect(walks.count("/music/Albums") == 2)
}

@MainActor @Test func aReloadDuringTheDropDoesNotUndoRecalculateSizes() async throws {
    let walks = CountedWalks()
    let pane = await walkedPane(walks).pane
    walks.holdNextRead()

    try binding(SizeCommands.recalculateSizes).run(CommandContext(pane: pane))
    let version = pane.stateVersion
    pane.reload()
    await settle { pane.stateVersion != version && pane.state.isLoaded }
    try await Task.sleep(for: .milliseconds(50))
    walks.releaseRead()

    await settle { albumsSize(pane) == .size(bytes: 2, isPartial: false) }
}

@MainActor @Test func aDropThatFailsIsLoggedAndKeepsTheSizesShown() async throws {
    let walks = CountedWalks()
    let pane = await walkedPane(walks).pane
    walks.failReads()

    try binding(SizeCommands.recalculateSizes).run(CommandContext(pane: pane))

    await settle { !walks.log.all.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    #expect(walks.log.all.contains { $0.contains("/music") })
    #expect(albumsSize(pane) == .size(bytes: 1, isPartial: false))
    #expect(walks.count("/music/Albums") == 1)
}

@MainActor @Test func recalculateSizesIsEnabledOnlyWhereSizesShow() async throws {
    let walks = CountedWalks()
    let settings = untouchedSettings()
    let fixture = PaneFixture(
        at: "/music", folders: ["/music": [folder("Albums")]], settings: settings)
    let pane = fixture.pane
    let recalculate = try binding(SizeCommands.recalculateSizes)
    let isEnabled = try #require(recalculate.isEnabled)
    #expect(!isEnabled(CommandContext(pane: pane)))

    pane.folderSizes = walks.service()
    #expect(isEnabled(CommandContext(pane: pane)))

    settings.folderSizes = false
    #expect(!isEnabled(CommandContext(pane: pane)))
    settings.folderSizes = true

    pane.setViewMode(.column)
    #expect(!isEnabled(CommandContext(pane: pane.commandPane)))
}

@Test func recalculateSizesIsMenuOnly() {
    #expect(SizeCommands.recalculateSizes.chords.isEmpty)
    #expect(
        AppCommands.sets.contains { ObjectIdentifier($0) == ObjectIdentifier(SizeCommands.self) })
}
