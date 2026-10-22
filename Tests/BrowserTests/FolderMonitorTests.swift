import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

/// Every patch in `changes`, in order.
private func patches(_ changes: [FolderChange]) -> [FolderChange.Patch] {
    changes.flatMap { change -> [FolderChange.Patch] in
        if case .patches(let patches) = change { patches } else { [] }
    }
}

private func updatedNames(_ changes: [FolderChange]) -> [String] {
    patches(changes).compactMap { if case .update(let entry) = $0 { entry.name } else { nil } }
}

private func removedNames(_ changes: [FolderChange]) -> [String] {
    patches(changes).compactMap { if case .remove(let name) = $0 { name } else { nil } }
}

private func rowsOf(_ listing: Listing) -> [DirectoryEntry] {
    (0..<listing.count).map { listing[$0] }
}

/// A listing that folder changes patch as they arrive, on the monitor's queue.
private final class LiveListing: @unchecked Sendable {
    private let lock = NSLock()
    private var listing: Listing

    init(_ listing: Listing) { self.listing = listing }

    func apply(_ change: FolderChange) {
        guard case .patches(let patches) = change else { return }
        lock.lock()
        defer { lock.unlock() }
        for patch in patches {
            switch patch {
            case .update(let entry): listing.update(entry)
            case .remove(let name): listing.remove(named: name)
            }
        }
    }

    var rows: [DirectoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return rowsOf(listing)
    }
}

private func freshListing(of folder: String) throws -> Listing {
    var entries: [DirectoryEntry] = []
    try DirectoryLister().list(folder) { entries += $0 }
    return Listing(entries)
}

@Suite(.serialized) struct FolderMonitorTests {
    private func monitor(
        _ folder: TemporaryFolder, volume: VolumeKind
    ) throws -> (FolderMonitor, EventLog<FolderChange>) {
        let log = EventLog<FolderChange>()
        let monitor = try FolderMonitor(
            location: Location(path: folder.url.path), volume: volume, onChange: log.append)
        return (monitor, log)
    }

    @Test func localFolderPatchesCreateDeleteAndRename() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let (monitor, log) = try monitor(folder, volume: .local)
        defer { monitor.stop() }
        #expect(monitor.watcher == .fileEvents)

        try Data(count: 5).write(to: folder.url.appending(path: "created"))
        #expect(log.wait { updatedNames($0).contains("created") })
        let created = patches(log.all).compactMap {
            if case .update(let entry) = $0, entry.name == "created" { entry } else { nil }
        }
        #expect(created.last?.type == .regular)

        try FileManager.default.moveItem(
            at: folder.url.appending(path: "created"), to: folder.url.appending(path: "renamed"))
        #expect(
            log.wait {
                removedNames($0).contains("created") && updatedNames($0).contains("renamed")
            })

        try FileManager.default.removeItem(at: folder.url.appending(path: "renamed"))
        #expect(log.wait { removedNames($0).contains("renamed") })
    }

    @Test func networkFolderUsesVnodeAndRequestsRelist() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let (monitor, log) = try monitor(folder, volume: .network)
        defer { monitor.stop() }
        #expect(monitor.watcher == .vnode)

        try Data().write(to: folder.url.appending(path: "created"))

        #expect(log.wait { $0.contains(.relist) })
        #expect(patches(log.all).isEmpty)
    }

    @Test func stopReleasesTheDescriptor() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let (monitor, _) = try monitor(folder, volume: .network)
        let descriptor = try #require(monitor.vnodeDescriptor)
        func openPath() -> String? {
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            return fcntl(descriptor, F_GETPATH, &buffer) == -1
                ? nil
                : String(
                    decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self
                )
        }
        #expect(openPath() == folder.url.path)

        monitor.stop()

        #expect(openPath() != folder.url.path)
        #expect(monitor.vnodeDescriptor == nil)
    }

    @Test func stoppedMonitorSendsNothing() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let (monitor, log) = try monitor(folder, volume: .local)
        monitor.stop()

        try Data().write(to: folder.url.appending(path: "after stop"))

        #expect(!log.wait(timeout: 1) { !$0.isEmpty })
    }

    @Test func missingFolderThrowsNotFound() {
        #expect(throws: ListingError(path: "/no/such/folder", code: ENOENT)) {
            try FolderMonitor(location: Location(path: "/no/such/folder"), volume: .network) { _ in
            }
        }
    }

    @Test func eventsForDirectChildrenBecomePatches() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        try Data(count: 3).write(to: folder.url.appending(path: "kept"))
        let events = [
            FileEvent(path: folder.url.path, flags: [.modified]),
            FileEvent(path: folder.url.appending(path: "kept").path, flags: [.created]),
            FileEvent(path: folder.url.appending(path: "kept").path, flags: [.modified]),
            FileEvent(path: folder.url.appending(path: "gone").path, flags: [.removed]),
            FileEvent(path: folder.url.appending(path: "deep/inside").path, flags: [.created]),
        ]

        let change = FolderMonitor.change(for: events, in: folder.url.path)

        let entry = try DirectoryLister().entry(named: "kept", inDirectory: folder.url.path)
        #expect(change == .patches([.update(try #require(entry)), .remove(name: "gone")]))
    }

    @Test func eventsForOtherPathsOnlyAreIgnored() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let events = [
            FileEvent(path: folder.url.path, flags: [.modified]),
            FileEvent(path: folder.url.appending(path: "deep/inside").path, flags: [.created]),
        ]

        #expect(FolderMonitor.change(for: events, in: folder.url.path) == nil)
    }

    @Test func rescanAndRootChangeRequestRelist() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let named = FileEvent(path: folder.url.appending(path: "a").path, flags: [.created])

        for flag in [FileEvent.Flags.mustRescan, .rootChanged] {
            let event = FileEvent(path: folder.url.path, flags: [flag])
            #expect(FolderMonitor.change(for: [named, event], in: folder.url.path) == .relist)
        }
    }

    @Test func writingAnExistingFileUpdatesItsRow() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let file = folder.url.appending(path: "grows")
        try Data(count: 3).write(to: file)
        let live = LiveListing(try freshListing(of: folder.url.path))
        let log = EventLog<FolderChange>()
        let monitor = try FolderMonitor(
            location: Location(path: folder.url.path), volume: .local
        ) { change in
            live.apply(change)
            log.append(change)
        }
        defer { monitor.stop() }
        #expect(live.rows.map(\.size) == [3])

        // FSEvents reports a write when the file is closed.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(count: 4_000))
        try handle.close()

        #expect(log.wait { _ in live.rows.map(\.size) == [4_003] })
    }

    @Test func renamingTheWatchedFolderRequestsRelist() throws {
        let parent = try TemporaryFolder("FolderMonitorTests")
        let watched = parent.url.appending(path: "watched")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: false)
        let log = EventLog<FolderChange>()
        let monitor = try FolderMonitor(
            location: Location(path: watched.path), volume: .local, onChange: log.append)
        defer { monitor.stop() }

        try FileManager.default.moveItem(
            at: watched, to: parent.url.appending(path: "moved"))

        #expect(log.wait { $0.contains(.relist) })
    }

    @Test func burstOfCreatesLeavesTheListingEqualToAFreshOne() throws {
        let folder = try TemporaryFolder("FolderMonitorTests")
        let live = LiveListing(try freshListing(of: folder.url.path))
        let log = EventLog<FolderChange>()
        let monitor = try FolderMonitor(
            location: Location(path: folder.url.path), volume: .local
        ) { change in
            live.apply(change)
            log.append(change)
        }
        defer { monitor.stop() }

        for index in 0..<1_000 {
            try Data(count: index % 7).write(to: folder.url.appending(path: "file-\(index)"))
        }

        let fresh = rowsOf(try freshListing(of: folder.url.path))
        #expect(fresh.count == 1_000)
        #expect(log.wait(timeout: 20) { _ in live.rows == fresh })
        #expect(!log.all.contains(.relist))
    }
}

/// The path `descriptor` refers to, or nil if it isn't open.
private func openPath(_ descriptor: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard fcntl(descriptor, F_GETPATH, &buffer) != -1 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}

/// A monitor on a disk image's root, watched as a network folder is.
private func vnodeMonitor(
    _ image: DiskImage, onChange: @escaping @Sendable (FolderChange) -> Void
) async throws -> FolderMonitor {
    let location = Location(path: image.mountPoint)
    let monitor = try await BlockingCallThread.run {
        try FolderMonitor(location: location, volume: .network, onChange: onChange)
    }
    #expect(monitor.watcher == .vnode)
    return monitor
}

@MainActor @Suite(.serialized) struct FolderMonitorDiskImageTests {
    /// The watch opens its folder for events only, which doesn't keep a volume from unmounting,
    /// so will-unmount leaves it: if the unmount is refused, the pane is still watched.
    @Test func willUnmountLeavesThePaneMonitorAndAPlainDetachRevokesIt() async throws {
        let image = try await DiskImage("FolderMonitorTests")
        let pane = Pane(
            location: Location(path: image.mountPoint), service: ListingService(),
            systemActions: StubSystemActions(), settings: untouchedSettings())
        await settle { pane.state.isLoaded }
        let monitor = try await vnodeMonitor(image) { _ in }
        pane.monitor = monitor
        let descriptor = try #require(monitor.vnodeDescriptor)

        VolumeEvents.willUnmount(at: image.mountPoint)

        #expect(pane.monitor === monitor)
        #expect(openPath(descriptor) == image.mountPoint)
        try await image.detach()
        await settle { descriptorIsClosed(descriptor, wasAt: image.mountPoint) }
    }

    @Test func forcedDetachRevokesTheWatchAndTheMonitorStopsCleanly() async throws {
        let image = try await DiskImage("FolderMonitorTests")
        let log = EventLog<FolderChange>()
        let monitor = try await vnodeMonitor(image, onChange: log.append)
        let descriptor = try #require(monitor.vnodeDescriptor)

        try await image.detach(force: true)

        await settle { descriptorIsClosed(descriptor, wasAt: image.mountPoint) }
        monitor.stop()
        #expect(monitor.vnodeDescriptor == nil)
        #expect(log.all.isEmpty)
    }
}

/// Watches the folder named by `SEARCHER_NAS_FOLDER` and waits for a change made on the server.
/// Skipped unless it is set. Run it as
/// `SEARCHER_NAS_FOLDER=/Volumes/main/searcher-spike ./scripts/test --filter nasChangeRelists`,
/// then create, rename or delete a file in that folder from another machine.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SEARCHER_NAS_FOLDER"] != nil))
func nasChangeRelistsForManualCheck() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["SEARCHER_NAS_FOLDER"])
    let log = EventLog<FolderChange>()
    let monitor = try await BlockingCallThread.run {
        try FolderMonitor(location: Location(path: path), onChange: log.append)
    }
    defer { monitor.stop() }
    #expect(monitor.volume == .network)
    #expect(monitor.watcher == .vnode)
    print("Watching \(path) as a network volume. Change it on the NAS within 120 s.")

    let started = Date()
    let relisted = log.wait(timeout: 120) { $0.contains(.relist) }

    #expect(relisted)
    print("Re-list requested \(Date().timeIntervalSince(started)) s after the watch started.")
}
