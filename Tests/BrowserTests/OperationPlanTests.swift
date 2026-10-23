import Base
import Darwin
import Foundation
import TestSupport
import Testing

@testable import Browser

private let local = VolumeIdentity(device: "/dev/fake1", mountPoint: "/L", kind: .local)
private let other = VolumeIdentity(device: "/dev/fake2", mountPoint: "/O", kind: .local)

/// Paths under `/O` are on `other`, every other path on `local`.
private func fakeVolume(_ path: String) -> VolumeIdentity {
    isPath(path, atOrUnder: "/O") ? other : local
}

/// Volume reads and measures made while planning, so a test can see that a plan read nothing.
private final class Reads: @unchecked Sendable {
    private let lock = NSLock()
    private var volumes: [String] = []
    private var measured: [String] = []

    var volumeReads: [String] { lock.withLock { volumes } }
    var measures: [String] { lock.withLock { measured } }

    func plan(_ operation: FileOperation, missing: Set<String> = []) throws -> OperationPlan {
        try OperationPlan.make(
            for: operation,
            volumeOf: { path throws(ListingError) in
                self.lock.withLock { self.volumes.append(path) }
                return fakeVolume(path)
            },
            measure: { path, _ in
                self.lock.withLock { self.measured.append(path) }
                if missing.contains(path) {
                    throw FileOperationError(reason: .sourceGone, path: path, errno: ENOENT)
                }
                return TreeSizeWalker.Total(bytes: 100, files: 2, isPartial: false)
            },
            inspect: { _ throws(FileOperationError) in nil },
            identify: { _ throws(FileOperationError) in nil },
            isCancelled: { false })
    }
}

@Test(arguments: ["/L/music/album", "/L/music/album/disc 1"])
func aFolderIntoItselfOrItsSubfolderIsRefusedBeforeAnythingIsRead(into folder: String) throws {
    let reads = Reads()

    for operation in [
        FileOperation.copy(["/L/music/song.flac", "/L/music/album"], into: folder),
        .move(["/L/music/album"], into: folder),
    ] {
        #expect(throws: OperationState.Refusal.intoItself(source: "/L/music/album")) {
            try reads.plan(operation)
        }
    }
    #expect(reads.volumeReads.isEmpty)
    #expect(reads.measures.isEmpty)
}

/// APFS compares names without case, and a trailing slash names the same folder.
@Test(arguments: [
    ("/L/Music/Album", "/l/music/album/Disc 1"),
    ("/L/music/album/", "/L/music/album"),
    ("/L/music/album/", "/L/music/album/disc 1/"),
])
func intoItselfIgnoresCaseAndTrailingSlashes(source: String, into folder: String) throws {
    #expect(throws: OperationState.Refusal.intoItself(source: source)) {
        try Reads().plan(.copy([source], into: folder))
    }
}

@Test func aCopyIntoAFolderNamedLikeTheSourceIsNotIntoItself() throws {
    let plan = try Reads().plan(.copy(["/L/music/album"], into: "/L/music/album 2"))

    #expect(plan.items.map(\.destination) == ["/L/music/album 2/album"])
}

@Test func aCopyIsPreScannedAndRunsInTheLaneOfItsDestinationVolume() throws {
    let reads = Reads()

    let plan = try reads.plan(.copy(["/L/a", "/L/b"], into: "/O/backup"))

    #expect(plan.lane == other)
    #expect(
        plan.items == [
            OperationPlan.Item(
                source: "/L/a", destination: "/O/backup/a",
                size: TreeSizeWalker.Total(bytes: 100, files: 2, isPartial: false),
                crossesVolumes: false, conflict: nil),
            OperationPlan.Item(
                source: "/L/b", destination: "/O/backup/b",
                size: TreeSizeWalker.Total(bytes: 100, files: 2, isPartial: false),
                crossesVolumes: false, conflict: nil),
        ])
    #expect(plan.total == TreeSizeWalker.Total(bytes: 200, files: 4, isPartial: false))
}

@Test func anItemThatCantBeMeasuredFailsAloneAndTheRestArePlanned() throws {
    let plan = try Reads().plan(.copy(["/L/gone", "/L/kept"], into: "/O"), missing: ["/L/gone"])

    #expect(plan.items.map(\.source) == ["/L/kept"])
    #expect(
        plan.failures == [FileOperationError(reason: .sourceGone, path: "/L/gone", errno: ENOENT)])
    #expect(plan.total == TreeSizeWalker.Total(bytes: 100, files: 2, isPartial: false))
}

@Test func aMoveWithinOneVolumeIsNotScannedAndRunsOutsideTheLanes() throws {
    let reads = Reads()

    let plan = try reads.plan(.move(["/L/a", "/L/b"], into: "/L/sorted"))

    #expect(plan.lane == nil)
    #expect(plan.items.map(\.crossesVolumes) == [false, false])
    #expect(plan.items.map(\.size) == [nil, nil])
    #expect(reads.measures.isEmpty)
    #expect(plan.total == nil)
}

@Test func aMoveToAnotherVolumeIsScannedAndRunsInTheDestinationsLane() throws {
    let reads = Reads()

    let plan = try reads.plan(.move(["/L/a"], into: "/O/sorted"))

    #expect(plan.lane == other)
    #expect(plan.items.map(\.crossesVolumes) == [true])
    #expect(reads.measures == ["/L/a"])
}

@Test func renameTrashAndNewFolderReadNothingAndRunOutsideTheLanes() throws {
    let reads = Reads()

    let rename = try reads.plan(.rename("/L/a.txt", to: "b.txt"))
    let trash = try reads.plan(.trash(["/L/a", "/L/b"]))
    let newFolder = try reads.plan(.newFolder(in: "/L"))

    #expect(rename.items.map(\.destination) == ["/L/b.txt"])
    #expect(trash.items.map(\.source) == ["/L/a", "/L/b"])
    #expect(newFolder.items.map(\.source) == ["/L"])
    #expect([rename.lane, trash.lane, newFolder.lane] == [nil, nil, nil])
    #expect(reads.volumeReads.isEmpty)
    #expect(reads.measures.isEmpty)
}

@Test func aDuplicateIsScannedAndRunsInTheLaneOfItsFolder() throws {
    let plan = try Reads().plan(.duplicate(["/O/photos/a.jpg"]))

    #expect(plan.lane == other)
    #expect(
        plan.items.map(\.size) == [TreeSizeWalker.Total(bytes: 100, files: 2, isPartial: false)])
}

/// The pre-scan counts what `FileCopier` counts, so a copy ends at its total.
@Test func measureCountsAFileATreeAndASymlinkAsTheCopierDoes() async throws {
    let folder = try TemporaryFolder("OperationPlanTests")
    let root = folder.url.path
    try FileManager.default.createDirectory(
        atPath: root + "/tree/inner", withIntermediateDirectories: true)
    try Data(count: 1_000).write(to: URL(fileURLWithPath: root + "/tree/one.bin"))
    try Data(count: 24).write(to: URL(fileURLWithPath: root + "/tree/inner/two.bin"))
    try FileManager.default.createSymbolicLink(
        atPath: root + "/tree/link", withDestinationPath: "one.bin")
    try FileManager.default.createSymbolicLink(
        atPath: root + "/link", withDestinationPath: "tree")

    let (tree, file, link) = try await BlockingCallThread.run {
        (
            try OperationPlan.measure(root + "/tree") { false },
            try OperationPlan.measure(root + "/tree/one.bin") { false },
            try OperationPlan.measure(root + "/link") { false }
        )
    }

    #expect(tree == TreeSizeWalker.Total(bytes: 1_024, files: 3, isPartial: false))
    #expect(file == TreeSizeWalker.Total(bytes: 1_000, files: 1, isPartial: false))
    #expect(link == TreeSizeWalker.Total(bytes: 0, files: 1, isPartial: false))
    await #expect(
        throws: FileOperationError(reason: .sourceGone, path: root + "/gone", errno: ENOENT)
    ) {
        try await BlockingCallThread.run { try OperationPlan.measure(root + "/gone") { false } }
    }
}
