import Base
import Darwin
import Foundation

/// What one operation will do, worked out before it runs: each item with where it goes and,
/// for an item that is copied, its size from a pre-scan; the volume lane it waits in; and the
/// items that failed before anything ran.
public struct OperationPlan: Equatable, Sendable {
    public struct Item: Equatable, Sendable {
        public let source: String
        /// Where the item goes; nil for a trash or a delete, for a duplicate, whose name is
        /// picked when it runs, and for the folder a new folder is made in.
        public let destination: String?
        /// The pre-scan of an item that is copied; nil for one that isn't.
        public let size: TreeSizeWalker.Total?
        /// A move of this item copies it to another volume and then deletes the source.
        public let crossesVolumes: Bool
        /// The item already at `destination`, for a copy or a move; nil when there is none.
        public let conflict: Conflict?

        public init(
            source: String, destination: String?, size: TreeSizeWalker.Total?,
            crossesVolumes: Bool, conflict: Conflict?
        ) {
            self.source = source
            self.destination = destination
            self.size = size
            self.crossesVolumes = crossesVolumes
            self.conflict = conflict
        }
    }

    /// An item copied or moved onto a name its destination folder already has.
    public struct Conflict: Equatable, Sendable {
        public let source: ConflictRequest.Item
        public let existing: ConflictRequest.Item

        public init(source: ConflictRequest.Item, existing: ConflictRequest.Item) {
            self.source = source
            self.existing = existing
        }
    }

    public let items: [Item]
    /// The volume whose lane the operation waits in: the one it copies to. Nil for an operation
    /// that copies nothing, which runs at once.
    public let lane: VolumeIdentity?
    /// Items that can't run, such as a source that is gone, and a destination whose volume
    /// can't be read.
    public let failures: [FileOperationError]

    /// The sizes of the items that are copied, added up; nil when no item is.
    public var total: TreeSizeWalker.Total? { Self.total(of: items) }

    /// The sizes of those of `items` that are copied, added up; nil when none is.
    static func total(of items: [Item]) -> TreeSizeWalker.Total? {
        let sizes = items.compactMap(\.size)
        guard !sizes.isEmpty else { return nil }
        return TreeSizeWalker.Total(
            bytes: sizes.reduce(0) { $0 + $1.bytes }, files: sizes.reduce(0) { $0 + $1.files },
            isPartial: sizes.contains { $0.isPartial })
    }

    /// Plans `operation`. A folder copied or moved into itself is refused before anything is
    /// read, comparing paths as `FileOperation.comparable` gives them. Copies, duplicates and
    /// moves to another volume read the volumes involved with `volumeOf` and pre-scan each item
    /// with `measure`. Copies and moves look for each item's name in the destination folder
    /// with `inspect`, top-level items only, and inspect the source of each that is there. An
    /// undo inspects each step's source, destination and destination folder, reads with
    /// `identify` the identity of each source the record has one for, reads the volumes of its
    /// moves and of the copies it makes again, and pre-scans what it copies. Nothing else
    /// reads the file system. Blocks while it reads, so it runs on a
    /// `BlockingCallThread`.
    ///
    /// - Throws: `OperationState.Refusal`, or `CancellationError` once `isCancelled` returns true.
    static func make(
        for operation: FileOperation,
        volumeOf: (String) throws(ListingError) -> VolumeIdentity,
        measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        inspect: (String) throws(FileOperationError) -> ConflictRequest.Item?,
        identify: FileOperationQueue.Identifier,
        isCancelled: @escaping () -> Bool
    ) throws -> OperationPlan {
        switch operation {
        case .copy(let sources, let folder), .move(let sources, let folder):
            if let source = FileOperation.source(holding: folder, among: sources) {
                throw OperationState.Refusal.intoItself(source: source)
            }
            let isMove = if case .move = operation { true } else { false }
            return try transfer(
                sources, into: folder, isMove: isMove, volumeOf: volumeOf, measure: measure,
                inspect: inspect, isCancelled: isCancelled)
        case .duplicate(let sources):
            guard let first = sources.first else { return empty }
            let parent = (first as NSString).deletingLastPathComponent
            let lane: VolumeIdentity
            do {
                lane = try volumeOf(parent)
            } catch {
                return OperationPlan(items: [], lane: nil, failures: [failure(error)])
            }
            var items: [Item] = []
            var failures: [FileOperationError] = []
            for source in sources {
                switch try measured(source, measure: measure, isCancelled: isCancelled) {
                case .success(let size):
                    items.append(
                        Item(
                            source: source, destination: nil, size: size, crossesVolumes: false,
                            conflict: nil))
                case .failure(let error): failures.append(error)
                }
            }
            return OperationPlan(items: items, lane: lane, failures: failures)
        case .trash(let paths), .deleteImmediately(let paths):
            return OperationPlan(
                items: paths.map {
                    Item(
                        source: $0, destination: nil, size: nil, crossesVolumes: false,
                        conflict: nil)
                }, lane: nil, failures: [])
        case .rename(let path, let name):
            return OperationPlan(
                items: [
                    Item(
                        source: path, destination: FileOperation.renamed(path, to: name),
                        size: nil, crossesVolumes: false, conflict: nil)
                ], lane: nil, failures: [])
        case .receive:
            preconditionFailure("\(operation) is reported, never planned")
        case .newFolder(let folder):
            return OperationPlan(
                items: [
                    Item(
                        source: folder, destination: nil, size: nil, crossesVolumes: false,
                        conflict: nil)
                ], lane: nil, failures: [])
        case .undo(let record, _):
            return try undoing(
                FileOperation.steps(undoing: record), identities: record.identities,
                volumeOf: volumeOf, measure: measure, inspect: inspect, identify: identify,
                isCancelled: isCancelled)
        }
    }

    private static let empty = OperationPlan(items: [], lane: nil, failures: [])

    /// Plans a copy, or a move, of `sources` into `folder`. Every copy waits in the lane of
    /// `folder`'s volume; a move only when an item crosses volumes, judged by the volume of the
    /// item's parent folder, read once per folder.
    private static func transfer(
        _ sources: [String], into folder: String, isMove: Bool,
        volumeOf: (String) throws(ListingError) -> VolumeIdentity,
        measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        inspect: (String) throws(FileOperationError) -> ConflictRequest.Item?,
        isCancelled: @escaping () -> Bool
    ) throws -> OperationPlan {
        let destination: VolumeIdentity
        do {
            destination = try volumeOf(folder)
        } catch {
            return OperationPlan(items: [], lane: nil, failures: [failure(error)])
        }
        var parentVolumes: [String: Result<VolumeIdentity, ListingError>] = [:]
        var items: [Item] = []
        var failures: [FileOperationError] = []
        for source in sources {
            if isCancelled() { throw CancellationError() }
            var crosses = true
            if isMove {
                let parent = (source as NSString).deletingLastPathComponent
                let volume =
                    parentVolumes[parent]
                    ?? Result { () throws(ListingError) in try volumeOf(parent) }
                parentVolumes[parent] = volume
                switch volume {
                case .success(let volume): crosses = volume != destination
                case .failure(let error):
                    failures.append(failure(error))
                    continue
                }
            }
            var size: TreeSizeWalker.Total?
            if crosses || !isMove {
                switch try measured(source, measure: measure, isCancelled: isCancelled) {
                case .success(let measured): size = measured
                case .failure(let error):
                    failures.append(error)
                    continue
                }
            }
            let destination = FileOperation.path(of: source, in: folder)
            var conflict: Conflict?
            do throws(FileOperationError) {
                if let existing = try inspect(destination) {
                    guard let item = try inspect(source) else {
                        throw FileOperationError(reason: .sourceGone, path: source, errno: ENOENT)
                    }
                    conflict = Conflict(source: item, existing: existing)
                }
            } catch {
                failures.append(error)
                continue
            }
            items.append(
                Item(
                    source: source, destination: destination, size: size,
                    crossesVolumes: isMove && crosses, conflict: conflict))
        }
        let copies = items.contains { $0.size != nil }
        return OperationPlan(items: items, lane: copies ? destination : nil, failures: failures)
    }

    /// Plans an undo's steps, one item each in order. First it checks, with `inspect`, that each
    /// step's item is at its source, its destination is free and the folder it goes in is
    /// there, as the steps before it leave them, and, with `identify`, that an item the record
    /// has an identity for is still that item, not another put at its path since; if any isn't,
    /// it plans no items and each such path is a failure, so nothing is changed. A copy made
    /// again only reads its source, so its identity isn't checked. A move whose two folders are
    /// on different volumes is copied, as is a copy made again, so each is pre-scanned and the
    /// undo waits in the lane of the first such destination's volume.
    private static func undoing(
        _ steps: [FileOperation.UndoStep], identities: [String: OperationRecord.ItemIdentity],
        volumeOf: (String) throws(ListingError) -> VolumeIdentity,
        measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        inspect: (String) throws(FileOperationError) -> ConflictRequest.Item?,
        identify: FileOperationQueue.Identifier,
        isCancelled: @escaping () -> Bool
    ) throws -> OperationPlan {
        // Whether a path holds an item once the earlier steps have run, by comparable path.
        var after: [String: Bool] = [:]
        func isTaken(_ path: String) throws(FileOperationError) -> Bool {
            if let taken = after[FileOperation.comparable(path)] { return taken }
            return try inspect(path) != nil
        }
        var failures: [FileOperationError] = []
        func gone(_ path: String) {
            let error = FileOperationError(reason: .sourceGone, path: path, errno: ENOENT)
            if !failures.contains(error) { failures.append(error) }
        }
        for step in steps {
            if isCancelled() { throw CancellationError() }
            let source = step.source
            do throws(FileOperationError) {
                if let source {
                    if let taken = after[FileOperation.comparable(source)] {
                        if !taken { gone(source) }
                    } else if try inspect(source) == nil {
                        gone(source)
                    } else if !step.readsSource,
                        let recorded = identities[FileOperation.comparable(source)],
                        try identify(source) != recorded
                    {
                        // A copy made again copies whatever is at its source now, as a copy
                        // does, so only an item it would change is checked.
                        failures.append(
                            FileOperationError(reason: .notTheSameItem, path: source, errno: nil))
                    }
                }
                if let destination = step.destination {
                    // A rename that changes only case finds the item itself at its destination.
                    if source.map(FileOperation.comparable)
                        != FileOperation.comparable(destination),
                        try isTaken(destination)
                    {
                        failures.append(
                            FileOperationError(reason: .exists, path: destination, errno: EEXIST))
                    }
                    let folder = (destination as NSString).deletingLastPathComponent
                    if try !isTaken(folder) { gone(folder) }
                }
            } catch {
                failures.append(error)
            }
            if let source, !step.readsSource {
                after[FileOperation.comparable(source)] = false
            }
            if let destination = step.destination {
                after[FileOperation.comparable(destination)] = true
            }
        }
        guard failures.isEmpty else {
            return OperationPlan(items: [], lane: nil, failures: failures)
        }
        var folderVolumes: [String: Result<VolumeIdentity, ListingError>] = [:]
        func volume(of path: String) throws(ListingError) -> VolumeIdentity {
            let folder = (path as NSString).deletingLastPathComponent
            let volume =
                folderVolumes[folder] ?? Result { () throws(ListingError) in try volumeOf(folder) }
            folderVolumes[folder] = volume
            return try volume.get()
        }
        var items: [Item] = []
        var lane: VolumeIdentity?
        for step in steps {
            if isCancelled() { throw CancellationError() }
            var crosses = false
            var size: TreeSizeWalker.Total?
            // The path the step copies from, if it copies.
            var copied: String?
            switch step {
            case .move(let from, let to):
                do throws(ListingError) {
                    let destination = try volume(of: to)
                    crosses = try volume(of: from) != destination
                    if crosses, lane == nil { lane = destination }
                } catch {
                    failures.append(failure(error))
                    continue
                }
                if crosses { copied = from }
            case .make(let path, .copy(let source)):
                do throws(ListingError) {
                    let destination = try volume(of: path)
                    if lane == nil { lane = destination }
                } catch {
                    failures.append(failure(error))
                    continue
                }
                copied = source
            case .putBack, .trash, .unmake, .make:
                break
            }
            if let copied {
                switch try measured(copied, measure: measure, isCancelled: isCancelled) {
                case .success(let measured): size = measured
                case .failure(let error):
                    failures.append(error)
                    continue
                }
            }
            guard let source = step.source ?? step.destination else {
                preconditionFailure("\(step) has neither a source nor a destination")
            }
            items.append(
                Item(
                    source: source, destination: step.destination, size: size,
                    crossesVolumes: crosses, conflict: nil))
        }
        guard failures.isEmpty else {
            return OperationPlan(items: [], lane: nil, failures: failures)
        }
        return OperationPlan(items: items, lane: lane, failures: [])
    }

    /// The pre-scan of `source`, or the error that kept it from being read; a cancel throws.
    private static func measured(
        _ source: String, measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        isCancelled: @escaping () -> Bool
    ) throws -> Result<TreeSizeWalker.Total, FileOperationError> {
        do {
            return .success(try measure(source, isCancelled))
        } catch let error as FileOperationError {
            return .failure(error)
        }
    }

    private static func failure(_ error: ListingError) -> FileOperationError {
        FileOperationError(errno: error.code, path: error.path)
    }

    /// The item at `path` as a `ConflictRequest` shows it, or nil if nothing is there. Symlinks
    /// aren't followed. Blocks the calling thread, which must be a `BlockingCallThread`.
    static func inspect(_ path: String) throws(FileOperationError) -> ConflictRequest.Item? {
        BlockingCallThread.requireCurrent()
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw FileOperationError(errno: errno, path: path)
        }
        let kind = info.st_mode & S_IFMT
        let modified = info.st_mtimespec
        return ConflictRequest.Item(
            path: path, isFolder: kind == S_IFDIR, bytes: kind == S_IFREG ? info.st_size : nil,
            modified: Date(
                timeIntervalSince1970: TimeInterval(modified.tv_sec) + TimeInterval(
                    modified.tv_nsec) / 1_000_000_000))
    }

    /// An identifier for one operation: the volume UUID and inode of the item at a path, or nil
    /// when nothing is there or its volume's inodes don't last (no
    /// `VOL_CAP_FMT_PERSISTENTOBJECTIDS`, as on FAT and exFAT, which make them up) or it has no
    /// UUID. What each volume reports is read once per operation, by `st_dev`, which holds while
    /// the operation runs. Symlinks aren't followed. Blocks the calling thread, which must be a
    /// `BlockingCallThread`.
    static func identifier() -> FileOperationQueue.Identifier {
        let volumes = VolumeUUIDs()
        return { path throws(FileOperationError) in
            BlockingCallThread.requireCurrent()
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw FileOperationError(errno: errno, path: path)
            }
            guard let volume = try volumes.uuid(of: info.st_dev, holding: path) else { return nil }
            return OperationRecord.ItemIdentity(volume: volume, inode: UInt64(info.st_ino))
        }
    }

    /// The UUID of each volume an identifier met, nil for one whose inodes don't last.
    final class VolumeUUIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var uuids: [dev_t: String?] = [:]

        func uuid(of device: dev_t, holding path: String) throws(FileOperationError) -> String? {
            if let known = lock.withLock({ uuids[device] }) { return known }
            let values: URLResourceValues
            do {
                values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
                    .volumeUUIDStringKey, .volumeSupportsPersistentIDsKey,
                ])
            } catch {
                // `URL` throws a Cocoa error that carries the system call's errno.
                let error = error as NSError
                let posix =
                    error.domain == NSPOSIXErrorDomain
                    ? error : error.userInfo[NSUnderlyingErrorKey] as? NSError
                guard let posix, posix.domain == NSPOSIXErrorDomain else {
                    throw FileOperationError(reason: .other, path: path, errno: nil)
                }
                throw FileOperationError(errno: Int32(posix.code), path: path)
            }
            let uuid = values.volumeSupportsPersistentIDs == true ? values.volumeUUIDString : nil
            lock.withLock { uuids[device] = uuid }
            return uuid
        }
    }

    /// The size of the item at `path` as `FileCopier` counts what it copies: a folder's from
    /// `TreeSizeWalker`; a file's logical size and one file; a symlink or anything else, no
    /// bytes and one file. Symlinks aren't followed. Blocks the calling thread, which must be a
    /// `BlockingCallThread`.
    ///
    /// - Throws: `FileOperationError` for an item that can't be read, and `CancellationError`
    ///   once `isCancelled` returns true.
    static func measure(_ path: String, isCancelled: () -> Bool) throws -> TreeSizeWalker.Total {
        BlockingCallThread.requireCurrent()
        var info = stat()
        if lstat(path, &info) != 0 { throw FileOperationError(errno: errno, path: path) }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            do {
                return try TreeSizeWalker().walk(path, isCancelled: isCancelled)
            } catch let error as ListingError {
                throw failure(error)
            }
        case S_IFREG:
            return TreeSizeWalker.Total(bytes: info.st_size, files: 1, isPartial: false)
        default:
            return TreeSizeWalker.Total(bytes: 0, files: 1, isPartial: false)
        }
    }
}
