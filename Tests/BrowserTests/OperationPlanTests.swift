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
    private var copied: [Int] = []

    /// For each call of the plan's `copies`, how many pre-scans had run.
    var copiesAfter: [Int] { lock.withLock { copied } }
    var volumeReads: [String] { lock.withLock { volumes } }
    var measures: [String] { lock.withLock { measured } }

    func plan(_ operation: FileOperation, missing: Set<String> = []) throws -> OperationPlan {
        try OperationPlan.make(
            for: operation,
            volumeOf: { path throws(ListingError) in
                self.lock.withLock { self.volumes.append(path) }
                return fakeVolume(path)
            },
            isCaseSensitive: { _ throws(ListingError) in false },
            measure: { path, _ in
                self.lock.withLock { self.measured.append(path) }
                if missing.contains(path) {
                    throw FileOperationError(reason: .sourceGone, path: path, errno: ENOENT)
                }
                return TreeSizeWalker.Total(bytes: 100, files: 2, isPartial: false)
            },
            inspect: { _ throws(FileOperationError) in nil },
            identify: { _ throws(FileOperationError) in nil },
            sourceHolding: { _, _ throws(FileOperationError) in nil },
            isCancelled: { false },
            copies: { self.lock.withLock { self.copied.append(self.measured.count) } })
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

/// Folding case is for a volume that doesn't tell case apart; Unicode is normalized either way,
/// as APFS and HFS+ ignore normalization on both kinds.
@Test func comparablePathsFoldCaseOnlyWhenAsked() {
    let decomposed = "/L/Cafe\u{301}/Foo/"
    #expect(FileOperation.comparable(decomposed) == "/l/caf\u{e9}/foo")
    #expect(FileOperation.comparable(decomposed, foldsCase: true) == "/l/caf\u{e9}/foo")
    #expect(FileOperation.comparable(decomposed, foldsCase: false) == "/L/Caf\u{e9}/Foo")
    #expect(
        FileOperation.comparable("/L/Foo", foldsCase: false)
            != FileOperation.comparable("/L/foo", foldsCase: false))
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

@Test func aVolumeThatCantBeReadFailsWithTheSystemsErrno() async throws {
    let path = "/no/such/folder/item"

    await #expect(throws: FileOperationError(reason: .sourceGone, path: path, errno: ENOENT)) {
        try await BlockingCallThread.run {
            try OperationPlan.VolumeUUIDs().uuid(of: 0, holding: path)
        }
    }
}

/// A move to another volume says it copies once the volumes are read and before its pre-scan,
/// which can take minutes, so an undo pressed meanwhile doesn't wait for it; a move within one
/// volume never says so.
@Test func aMoveToAnotherVolumeSaysItCopiesBeforeItsPreScan() throws {
    let across = Reads()
    _ = try across.plan(.move(["/L/a", "/L/b"], into: "/O/in"))
    #expect(across.copiesAfter.first == 0)
    #expect(across.measures == ["/L/a", "/L/b"])

    let within = Reads()
    _ = try within.plan(.move(["/L/a"], into: "/L/in"))
    #expect(within.copiesAfter.isEmpty)
}

/// On APFS, which keeps object IDs, an item is known by its volume's UUID and its inode, read
/// with `lstat` and the volume's resource values; nothing at the path reads nil.
@Test func theIdentifierReadsTheVolumeUUIDAndInodeWhereIDsPersist() async throws {
    let folder = try TemporaryFolder("OperationPlanTests")
    let path = folder.url.path + "/a.txt"
    try Data("a".utf8).write(to: URL(fileURLWithPath: path))
    var info = stat()
    #expect(lstat(path, &info) == 0)
    let uuid = try #require(
        URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeUUIDStringKey])
            .volumeUUIDString)

    let (identity, missing) = try await BlockingCallThread.run {
        () throws(FileOperationError) in
        let identify = OperationPlan.identifier()
        return (try identify(path), try identify(path + ".missing"))
    }

    #expect(identity == .persistent(volume: uuid, inode: UInt64(info.st_ino)))
    #expect(missing == nil)
}

/// Where IDs don't persist, an item is known by its type and birth time, so editing it in
/// place keeps it the same item; with no birth time, by its type, modification time and size.
@Test func aFingerprintIsTheTypeAndBirthTimeOrWithoutOneTheTimeAndSize() {
    var info = stat()
    info.st_mode = S_IFREG | 0o644
    info.st_birthtimespec = timespec(tv_sec: 1_000, tv_nsec: 5)
    info.st_mtimespec = timespec(tv_sec: 2_000, tv_nsec: 7)
    info.st_size = 42

    #expect(
        OperationPlan.identity(of: info, volume: nil)
            == .fingerprint(type: UInt16(S_IFREG), born: 1_000_000_000_005))
    #expect(
        OperationPlan.identity(of: info, volume: "V")
            == .persistent(volume: "V", inode: UInt64(info.st_ino)))
    info.st_birthtimespec = timespec(tv_sec: 0, tv_nsec: 0)
    #expect(
        OperationPlan.identity(of: info, volume: nil)
            == .fingerprintWithoutBirthTime(
                type: UInt16(S_IFREG), modified: 2_000_000_000_007, size: 42))
}
