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
    private var holdsWalks = false
    private var cancelledWalks = 0
    let log = EventLog<String>()

    func count(_ path: String) -> Int { condition.withLock { counts[path, default: 0] } }

    /// Walks that start from now on wait until they are cancelled.
    func holdWalks() {
        condition.withLock { holdsWalks = true }
    }

    /// The held walks that were cancelled.
    var cancelled: Int { condition.withLock { cancelledWalks } }

    /// The next volume read waits until `releaseRead`; the ones after it don't.
    func holdNextRead() {
        condition.withLock { holdsNextRead = true }
    }

    /// Whether a volume read is waiting for `releaseRead`.
    var isHoldingRead: Bool { condition.withLock { readIsHeld } }

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
            walk: { path, isCancelled in
                let (count, holds) = self.condition.withLock {
                    self.counts[path, default: 0] += 1
                    return (self.counts[path, default: 0], self.holdsWalks)
                }
                if holds {
                    while !isCancelled() { usleep(1000) }
                    self.condition.withLock { self.cancelledWalks += 1 }
                    throw CancellationError()
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
    let fixture = PaneFixture(
        at: "/music", folders: ["/music": [folder("Albums"), file("song")]],
        settings: sizedSettings())
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

@MainActor @Test func calculateSizesWithSizesOnWalksThePanesFoldersAgainPastTheKeptSizes()
    async throws
{
    let walks = CountedWalks()
    let pane = await walkedPane(walks).pane

    try binding(SizeCommands.calculateSizes).run(CommandContext(pane: pane))

    await settle { albumsSize(pane) == .size(bytes: 2, isPartial: false) }
    #expect(walks.count("/music/Albums") == 2)
}

@MainActor @Test func aReloadDuringTheDropDoesNotUndoCalculateSizes() async throws {
    let walks = CountedWalks()
    let pane = await walkedPane(walks).pane
    walks.holdNextRead()

    try binding(SizeCommands.calculateSizes).run(CommandContext(pane: pane))
    // The drop's own read is the one held; a reload that got there first would take the hold.
    await settle { walks.isHoldingRead }
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

    try binding(SizeCommands.calculateSizes).run(CommandContext(pane: pane))

    await settle { !walks.log.all.isEmpty }
    try await Task.sleep(for: .milliseconds(50))
    #expect(walks.log.all.contains { $0.contains("/music") })
    #expect(albumsSize(pane) == .size(bytes: 1, isPartial: false))
    #expect(walks.count("/music/Albums") == 1)
}

@MainActor @Test func calculateSizesIsEnabledInAListPaneWithSizesOnOrOff() async throws {
    let walks = CountedWalks()
    let settings = untouchedSettings()
    let fixture = PaneFixture(
        at: "/music", folders: ["/music": [folder("Albums")]], settings: settings)
    let pane = fixture.pane
    let calculate = try binding(SizeCommands.calculateSizes)
    let isEnabled = try #require(calculate.isEnabled)
    #expect(!isEnabled(CommandContext(pane: pane)))

    pane.folderSizes = walks.service()
    #expect(isEnabled(CommandContext(pane: pane)))

    settings.folderSizes = true
    #expect(isEnabled(CommandContext(pane: pane)))

    pane.setViewMode(.column)
    #expect(!isEnabled(CommandContext(pane: pane.commandPane)))
}

@Test func calculateSizesHasOptionCommandS() throws {
    #expect(SizeCommands.calculateSizes.chords == [KeyChord("s", modifiers: [.option, .command])])
    #expect(SizeCommands.calculateAllSizes.chords.isEmpty)
    #expect(
        AppCommands.sets.contains { ObjectIdentifier($0) == ObjectIdentifier(SizeCommands.self) })
}

@MainActor @Test func folderSizesAreOffByDefaultAndNoFolderIsWalked() async throws {
    let walks = CountedWalks()
    let pane = PaneFixture(at: "/music", folders: ["/music": [folder("Albums")]]).pane
    pane.folderSizes = walks.service()
    await settle { pane.state.isLoaded }
    pane.reload()
    try await Task.sleep(for: .milliseconds(50))

    #expect(!pane.settings.folderSizes)
    #expect(!pane.showsFolderSizes)
    #expect(walks.count("/music/Albums") == 0)
    #expect(albumsSize(pane) == nil)
}

@MainActor @Test func calculateAllSizesTogglesThePersistedSettingAndStartsAndCancelsWalks()
    async throws
{
    let temporary = try TemporaryFolder("SizeCommandsTests")
    let defaults = temporarySuite(in: temporary.url.path)
    let settings = Settings(defaults: defaults)
    let walks = CountedWalks()
    walks.holdWalks()
    let pane = PaneFixture(
        at: "/music", folders: ["/music": [folder("Albums")]], settings: settings
    ).pane
    pane.folderSizes = walks.service()
    await settle { pane.state.isLoaded }
    let toggle = try binding(SizeCommands.calculateAllSizes)
    let isChecked = try #require(toggle.isChecked)
    #expect(!isChecked(settings))

    toggle.run(CommandContext(pane: pane))
    #expect(isChecked(settings))
    #expect(Settings(defaults: defaults).folderSizes)
    await settle { walks.count("/music/Albums") == 1 }

    toggle.run(CommandContext(pane: pane))
    #expect(!isChecked(settings))
    #expect(!Settings(defaults: defaults).folderSizes)
    await settle { walks.cancelled == 1 }
    #expect(!pane.showsFolderSizes)
}

@MainActor @Test func calculateSizesWalksTheFolderOnceWithSizesOffAndARevisitShowsTheKeptSizes()
    async throws
{
    let walks = CountedWalks()
    let pane = PaneFixture(
        at: "/music",
        folders: [
            "/music": [folder("Albums"), file("song")], "/music/Albums": [folder("Disc 1")],
        ]
    ).pane
    pane.folderSizes = walks.service()
    await settle { pane.state.isLoaded }

    try binding(SizeCommands.calculateSizes).run(CommandContext(pane: pane))
    await settle { albumsSize(pane) == .size(bytes: 1, isPartial: false) }
    #expect(pane.showsFolderSizes)
    await settle { !pane.awaitsFolderSizes }

    pane.navigate(to: Location(path: "/music/Albums"))
    await settle { pane.location.path == "/music/Albums" && pane.state.isLoaded }
    pane.goBack()
    await settle {
        pane.location.path == "/music" && albumsSize(pane) == .size(bytes: 1, isPartial: false)
    }
    pane.reload()
    try await Task.sleep(for: .milliseconds(50))

    #expect(!pane.settings.folderSizes)
    #expect(!pane.awaitsFolderSizes)
    #expect(walks.count("/music/Albums") == 1)
    #expect(walks.count("/music/Albums/Disc 1") == 0)

    // A change to the folder's date drops its kept size, and it isn't walked again.
    let changed = DirectoryEntry(
        name: "Albums", type: .directory, size: nil, modified: testDate.addingTimeInterval(60),
        isHidden: false, isDataless: false)
    pane.apply(.patches([.update(changed)]), at: pane.location)
    await settle {
        guard let listing = pane.state.listing, let row = listing.row(named: "Albums") else {
            return false
        }
        return listing[row].modified == changed.modified
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(walks.count("/music/Albums") == 1)
}
