import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

private func volume(_ mountPoint: String, device: String? = nil) -> VolumeIdentity {
    VolumeIdentity(
        device: device ?? "/dev/\(mountPoint.split(separator: "/").last ?? "root")",
        mountPoint: mountPoint, kind: .local)
}

@MainActor
private func loadedTable(_ mounts: StubMounts) async -> MountTable {
    let table = mounts.table()
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

@MainActor @Test func theTableListsItsVolumesInTheKernelsOrderAndPlacesAServer() async throws {
    let root = volume("/")
    let disk = volume("/Volumes/a")
    let table = await loadedTable(StubMounts([mountedShare("music"), root, disk]))

    #expect(table.volumes == [mountedShare("music"), root, disk])
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

/// After a mount the table is read again before the mount point is looked up in it
/// (docs/decisions/0115-server-shares.md).
@MainActor @Test func refreshedReturnsOnceAReadOfTheNewMountsHasLanded() async {
    let root = volume("/")
    let mounts = StubMounts([root])
    let table = await loadedTable(mounts)
    let disk = volume("/Volumes/a")
    mounts.set([root, disk])

    #expect(await bounded(Task { await table.refreshed() }) != nil)

    #expect(table.volumes == [root, disk])
    // Two at once both return: the first with the second's read, which drops its own.
    mounts.set([root])
    let first = Task { await table.refreshed() }
    let second = Task { await table.refreshed() }
    #expect(await bounded(first) != nil)
    #expect(await bounded(second) != nil)
    #expect(table.volumes == [root])
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

    mounts.set([volume("/"), mountedShare("music")])
    table.refresh()
    await settle { runs == 1 }
    #expect(table.volumes == [volume("/"), mountedShare("music")])
}

@MainActor @Test func aReadThatChangesOnlyAVolumesFileSystemTypeChangesTheTable() async {
    func music(_ fsType: String) -> VolumeIdentity {
        VolumeIdentity(
            device: mountedShare("music").device, mountPoint: mountedShare("music").mountPoint,
            kind: .network,
            fsType: fsType)
    }
    let mounts = StubMounts([volume("/"), music("afpfs")])
    let table = await loadedTable(mounts)
    final class Owner {}
    let owner = Owner()
    var runs = 0
    table.observe(for: owner) { runs += 1 }

    mounts.set([volume("/"), music(VolumeIdentity.smbFSType)])
    table.refresh()
    await settle { runs == 1 }
    #expect(table.volumes.last?.fsType == VolumeIdentity.smbFSType)
}

/// A server chooses its shares' names. A row named so that it isn't one path component has no
/// mount point, and asking for one doesn't trap (docs/decisions/0115-server-shares.md).
@MainActor @Test func aRowNameThatIsntOnePathComponentHasNoMountPoint() async {
    let server = Server(host: "HAL9000._smb._tcp.local")!
    let share = VolumeIdentity(
        device: "//dylan@HAL9000._smb._tcp.local/main", mountPoint: "/Volumes/main",
        kind: .network, fsType: VolumeIdentity.smbFSType)
    let table = await loadedTable(StubMounts([volume("/"), share]))

    #expect(table.mountPoint(ofRow: "main", in: server) == Location(path: "/Volumes/main"))
    for name in ["a/b", "main/", "/", "", ".", "..", "main\u{0}", "ma\u{202E}in"] {
        #expect(table.mountPoint(ofRow: name, in: server) == nil, "\(name.debugDescription)")
    }
}
