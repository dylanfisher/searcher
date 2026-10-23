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
    /// undo reads each step's source and destination with `identify` and the volumes of its
    /// moves. Nothing else reads the file system. Blocks while it reads, so it runs on a
    /// `BlockingCallThread`.
    ///
    /// - Throws: `OperationState.Refusal`, or `CancellationError` once `isCancelled` returns true.
    static func make(
        for operation: FileOperation,
        volumeOf: (String) throws(ListingError) -> VolumeIdentity,
        measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        inspect: (String) throws(FileOperationError) -> ConflictRequest.Item?,
        identify: (String) throws(FileOperationError) -> OperationRecord.ItemIdentity?,
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
                volumeOf: volumeOf, measure: measure, identify: identify,
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

    /// Plans an undo's steps, one item each in order. First it checks, with `identify`, that
    /// each step's item is at its source and its destination is free, as the steps before it
    /// leave them, and that an item the record has an identity for is still that item, not
    /// another put at its path since; if any isn't, it plans no items and each such path is a
    /// failure, so nothing is changed. A move whose two folders are on different volumes is
    /// copied, so it is pre-scanned and the undo waits in the lane of the first such
    /// destination's volume.
    private static func undoing(
        _ steps: [FileOperation.UndoStep], identities: [String: OperationRecord.ItemIdentity],
        volumeOf: (String) throws(ListingError) -> VolumeIdentity,
        measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        identify: (String) throws(FileOperationError) -> OperationRecord.ItemIdentity?,
        isCancelled: @escaping () -> Bool
    ) throws -> OperationPlan {
        // Whether a path holds an item once the earlier steps have run, by comparable path.
        var after: [String: Bool] = [:]
        func isTaken(_ path: String) throws(FileOperationError) -> Bool {
            if let taken = after[FileOperation.comparable(path)] { return taken }
            return try identify(path) != nil
        }
        var failures: [FileOperationError] = []
        for step in steps {
            if isCancelled() { throw CancellationError() }
            let source = step.source
            do throws(FileOperationError) {
                if let taken = after[FileOperation.comparable(source)] {
                    if !taken {
                        failures.append(
                            FileOperationError(reason: .sourceGone, path: source, errno: ENOENT))
                    }
                } else if let identity = try identify(source) {
                    if let recorded = identities[source], recorded != identity {
                        failures.append(
                            FileOperationError(reason: .notTheSameItem, path: source, errno: nil))
                    }
                } else {
                    failures.append(
                        FileOperationError(reason: .sourceGone, path: source, errno: ENOENT))
                }
                // A rename that changes only case finds the item itself at its destination.
                if let destination = step.destination,
                    FileOperation.comparable(destination) != FileOperation.comparable(source),
                    try isTaken(destination)
                {
                    failures.append(
                        FileOperationError(reason: .exists, path: destination, errno: EEXIST))
                }
            } catch {
                failures.append(error)
            }
            after[FileOperation.comparable(source)] = false
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
            if case .move(let from, let to) = step {
                do throws(ListingError) {
                    let destination = try volume(of: to)
                    crosses = try volume(of: from) != destination
                    if crosses, lane == nil { lane = destination }
                } catch {
                    failures.append(failure(error))
                    continue
                }
                if crosses {
                    switch try measured(from, measure: measure, isCancelled: isCancelled) {
                    case .success(let measured): size = measured
                    case .failure(let error):
                        failures.append(error)
                        continue
                    }
                }
            }
            items.append(
                Item(
                    source: step.source, destination: step.destination, size: size,
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

    /// The device and inode of the item at `path`, or nil if nothing is there. Symlinks aren't
    /// followed. Blocks the calling thread, which must be a `BlockingCallThread`.
    static func identify(_ path: String) throws(FileOperationError) -> OperationRecord.ItemIdentity?
    {
        BlockingCallThread.requireCurrent()
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw FileOperationError(errno: errno, path: path)
        }
        return OperationRecord.ItemIdentity(device: info.st_dev, inode: info.st_ino)
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
