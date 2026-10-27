import Base
import BrowserTestSupport
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let main = ShareMountRequest(
    share: ShareRequest(server: testServer, user: "dylan"), name: "main")

/// Mounts with a gated mounter, over a table of stub mounts.
@MainActor
private struct Mounting {
    let mounter = GatedShareMounter()
    let mounts: StubMounts
    let table: MountTable
    let shareMounts: ShareMounts

    init(_ volumes: [VolumeIdentity] = [mountedShare("music")]) async {
        mounts = StubMounts(volumes)
        table = mounts.table()
        await table.firstRead()
        shareMounts = ShareMounts(mounter: mounter, table: table)
    }

    /// An ask to mount `request`, running until the test reads its value.
    func ask(_ request: ShareMountRequest = main) -> Task<ShareMounts.Result, Never> {
        Task { await shareMounts.mount(request) }
    }

    /// The handle of the `count`th start, once it has been made.
    func handle(ofStart count: Int = 1) async throws -> ShareMountHandle {
        #expect(await mounter.waitForStarts(count))
        return try #require(mounter.starts[count - 1].handle)
    }
}

@MainActor @Test func anAskStartsOneMountOnABlockingCallThreadAndASecondJoinsIt() async throws {
    let mounting = await Mounting()
    let first = mounting.ask()
    let handle = try await mounting.handle()
    let second = mounting.ask(ShareMountRequest(share: main.share, name: "MAIN"))
    await settle { mounting.shareMounts.askers(of: main) == 2 }

    mounting.mounts.set([mountedShare("music"), mountedShare("main")])
    #expect(mounting.mounter.complete(handle, mountPoints: ["/Volumes/main"]))

    #expect(await bounded(first) == .mounted("/Volumes/main"))
    #expect(await bounded(second) == .mounted("/Volumes/main"))
    #expect(mounting.mounter.starts.map(\.request) == [main])
    #expect(mounting.mounter.starts.allSatisfy { $0.onBlockingCallThread })
    // The answer waits for a read of the table, which has the new mount.
    #expect(mounting.table.volumes.contains(mountedShare("main")))
}

/// NetFS runs no completion after a non-zero return, so the mount ends with it.
@MainActor @Test func aStartThatFailsAtOnceAnswersWithItsStatus() async {
    let mounting = await Mounting()
    mounting.mounter.failStarts(with: EACCES)

    #expect(await bounded(mounting.ask()) == .failed(EACCES))
    #expect(mounting.shareMounts.askers(of: main) == 0)
    // The next ask starts again.
    mounting.mounter.failStarts(with: nil)
    _ = mounting.ask()
    #expect(await mounting.mounter.waitForStarts(2))
}

/// NetFS runs no completion after a cancel: each asker is answered here, and the mount is
/// cancelled only with the last, on a `BlockingCallThread`.
@MainActor @Test func theMountIsCancelledOnlyWithItsLastAsker() async throws {
    let mounting = await Mounting()
    let first = mounting.ask()
    let handle = try await mounting.handle()
    let second = mounting.ask()
    await settle { mounting.shareMounts.askers(of: main) == 2 }

    first.cancel()
    #expect(await bounded(first) == .cancelled)
    #expect(mounting.mounter.cancellations.isEmpty)
    second.cancel()
    #expect(await bounded(second) == .cancelled)
    await settle { mounting.mounter.cancellations == [handle] }
    #expect(mounting.mounter.cancelsOffBlockingThread == 0)
}

/// A last asker that leaves while NetFS's start hasn't returned its request ID: the mount is
/// cancelled once it has one.
@MainActor @Test func aMountLeftBeforeItsStartReturnsIsCancelledOnceItDoes() async throws {
    let mounting = await Mounting()
    mounting.mounter.holdStarts()
    let asking = mounting.ask()
    let handle = try await mounting.handle()

    asking.cancel()
    #expect(await bounded(asking) == .cancelled)
    #expect(mounting.mounter.cancellations.isEmpty)
    mounting.mounter.releaseStarts()

    await settle { mounting.mounter.cancellations == [handle] }
    #expect(!mounting.mounter.complete(handle))
}

@MainActor @Test func aCompletionAfterACancelIsIgnored() async throws {
    let mounting = await Mounting()
    let first = mounting.ask()
    let handle = try await mounting.handle()
    first.cancel()
    #expect(await bounded(first) == .cancelled)
    await settle { mounting.mounter.cancellations == [handle] }
    let second = mounting.ask()
    let next = try await mounting.handle(ofStart: 2)

    mounting.mounts.set([mountedShare("music"), mountedShare("main")])
    #expect(
        mounting.mounter.complete(
            handle, status: EACCES, mountPoints: [], evenIfCancelled: true))
    // Both completions run on the mounter's queue in order, so the late one reaches the mounts
    // first: had it been taken, the second ask would have its failure.
    #expect(mounting.mounter.complete(next, mountPoints: ["/Volumes/main"]))
    #expect(await bounded(second) == .mounted("/Volumes/main"))
}

/// A share mounted already answers `EEXIST`, maybe with no mount point: its mount point is the
/// table's mount of the server's share by its key.
@MainActor @Test func alreadyMountedWithNoMountPointIsFoundInTheTable() async throws {
    let mounting = await Mounting()
    let asking = mounting.ask(ShareMountRequest(share: main.share, name: "Main"))
    let handle = try await mounting.handle()
    mounting.mounts.set([
        mountedShare("main", of: "192.168.1.5"), mountedShare("music"),
        VolumeIdentity(
            device: "//dylan@\(testServerHost)/main", mountPoint: "/Volumes/main 1",
            kind: .network, fsType: VolumeIdentity.smbFSType),
    ])

    mounting.mounter.complete(handle, status: EEXIST)

    #expect(await bounded(asking) == .alreadyMounted("/Volumes/main 1"))
}

@MainActor @Test func alreadyMountedWithNoneInTheTableFails() async throws {
    let mounting = await Mounting()
    let asking = mounting.ask()
    mounting.mounter.complete(try await mounting.handle(), status: EEXIST)
    #expect(await bounded(asking) == .failed(EEXIST))
}

@MainActor
@Test(arguments: [
    (Int32(0), ["/Volumes/main"], ShareMounts.Result.mounted("/Volumes/main")),
    (EEXIST, ["/Volumes/main"], .alreadyMounted("/Volumes/main")),
    (ShareMounts.userCancelled, [], .cancelled),
    (EAUTH, [], .failed(EAUTH)),
    (-5998, [], .failed(-5998)),
])
func aCompletionAnswersByItsStatus(status: Int32, mountPoints: [String], result: ShareMounts.Result)
    async throws
{
    let mounting = await Mounting()
    let asking = mounting.ask()
    mounting.mounter.complete(try await mounting.handle(), status: status, mountPoints: mountPoints)
    #expect(await bounded(asking) == result)
}

@MainActor @Test func anAskFromACancelledTaskIsCancelledAndStartsNothing() async {
    let mounting = await Mounting()
    let asking = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return await mounting.shareMounts.mount(main)
    }
    #expect(await bounded(asking) == .cancelled)
    #expect(mounting.mounter.starts.isEmpty)
}
