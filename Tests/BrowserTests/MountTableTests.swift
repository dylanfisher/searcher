import Base
import Foundation
import TestSupport
import Testing

@testable import Browser

private func volume(_ mountPoint: String, device: String? = nil) -> VolumeIdentity {
    VolumeIdentity(
        device: device ?? "/dev/\(mountPoint.split(separator: "/").last ?? "root")",
        mountPoint: mountPoint, kind: .local)
}

/// The volumes a stub table reads, which a test changes between reads. Counts the reads and
/// records whether each ran on a `BlockingCallThread`.
private final class StubMounts: @unchecked Sendable {
    // `lock` guards everything below it.
    private let lock = NSLock()
    private var volumes: [VolumeIdentity]
    private var reads: [Bool] = []

    init(_ volumes: [VolumeIdentity]) {
        self.volumes = volumes
    }

    func set(_ volumes: [VolumeIdentity]) {
        lock.withLock { self.volumes = volumes }
    }

    func read() -> [VolumeIdentity] {
        lock.withLock {
            reads.append(BlockingCallThread.isCurrent)
            return volumes
        }
    }

    var readsOnBlockingCallThreads: [Bool] { lock.withLock { reads } }
}

@MainActor
private func loadedTable(_ mounts: StubMounts) async -> MountTable {
    let table = MountTable(read: mounts.read)
    await settle { table.volume(of: "/") != nil }
    return table
}

@MainActor @Test func aPathResolvesToTheLongestMountPointHoldingIt() async {
    let root = volume("/")
    let disk = volume("/Volumes/a")
    let table = await loadedTable(StubMounts([root, disk, volume("/Volumes/a b")]))

    #expect(table.volume(of: "/Volumes/a/b") == disk)
    #expect(table.volume(of: "/Volumes/a") == disk)
    #expect(table.volume(of: "/Users/someone") == root)
    // Only the text up to a slash counts: `/Volumes/ab` isn't on `/Volumes/a`.
    #expect(table.volume(of: "/Volumes/ab/c") == root)
}

@MainActor @Test func aPathResolvesWithoutCaseAndWithAnyNormalization() async {
    let disk = volume("/Volumes/Café")
    let table = await loadedTable(StubMounts([volume("/"), disk]))

    #expect(table.volume(of: "/volumes/cafe\u{301}/notes") == disk)
}

@MainActor @Test func theTableIsReadOffTheMainActor() async {
    let mounts = StubMounts([volume("/")])
    let table = await loadedTable(mounts)

    _ = table.volume(of: "/Users")
    _ = table.volume(of: "/Applications")

    // Other tests' mount events go through the one `VolumeEvents` and can make it read again,
    // so the count isn't checked.
    let reads = mounts.readsOnBlockingCallThreads
    #expect(!reads.isEmpty && reads.allSatisfy { $0 })
}

@MainActor @Test func aMountEventUpdatesTheTable() async {
    let root = volume("/")
    let mountPoint = "/Volumes/searcher-mount-table-\(UUID().uuidString)"
    let mounts = StubMounts([root])
    let table = await loadedTable(mounts)
    #expect(table.volume(of: mountPoint + "/b") == root)

    let disk = volume(mountPoint)
    mounts.set([root, disk])
    VolumeEvents.didMount(at: mountPoint)
    await settle { table.volume(of: mountPoint + "/b") == disk }

    mounts.set([root])
    VolumeEvents.didUnmount(at: mountPoint)
    await settle { table.volume(of: mountPoint + "/b") == root }
}

/// A share mounted directly in /Volumes from a host the source names.
private func share(_ name: String) -> VolumeIdentity {
    VolumeIdentity(
        device: "//dylan@HAL9000._smb._tcp.local/\(name)", mountPoint: "/Volumes/\(name)",
        kind: .network)
}

@MainActor @Test func theTableListsItsVolumesInTheKernelsOrderAndPlacesAServer() async throws {
    let root = volume("/")
    let disk = volume("/Volumes/a")
    let table = await loadedTable(StubMounts([share("music"), root, disk]))

    #expect(table.volumes == [share("music"), root, disk])
    let server = try #require(Server(host: "hal9000._smb._tcp.local"))
    #expect(table.server(holding: "/Volumes/music/Albums") == server)
    #expect(table.server(holding: "/Volumes/a/b") == nil)
    #expect(table.server(holding: "/Users") == nil)
}

@MainActor @Test func firstReadReturnsOnceAReadHasLanded() async {
    // Once open, the gate stays open: other tests' mount events make every table read again.
    let gate = DispatchSemaphore(value: 0)
    let table = MountTable(read: {
        gate.wait()
        gate.signal()
        return [volume("/")]
    })
    #expect(!table.isRead)
    gate.signal()

    await table.firstRead()

    #expect(table.isRead)
    #expect(table.volumes == [volume("/")])
    // At once, once read.
    await table.firstRead()
}

@MainActor @Test func theObserversRunAfterAReadThatChangedTheVolumesOnly() async {
    let mounts = StubMounts([volume("/")])
    let table = await loadedTable(mounts)
    final class Owner {}
    let owner = Owner()
    var runs = 0
    table.observe(for: owner) { runs += 1 }

    let landed = table.readsLanded
    table.refresh()
    await settle { table.readsLanded > landed }
    #expect(runs == 0)

    mounts.set([volume("/"), share("music")])
    table.refresh()
    await settle { runs == 1 }
    #expect(table.volumes == [volume("/"), share("music")])
}
