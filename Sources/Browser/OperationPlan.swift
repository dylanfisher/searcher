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
    /// For an undo, why the volume, or whether it tells case apart, couldn't be read for a pair
    /// of paths that differ only by case, by the path read: the check compared the pair without
    /// case, as on most volumes, and the queue logs it.
    var unreadCaseSensitivity: [String: ListingError] = [:]
    /// For a tag toggle, whether it adds the tag: some item it read lacks it. Otherwise every
    /// item has it, and the toggle takes it off each, as Finder's tag dots do.
    var addsTag = false

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
    /// read, comparing paths as `FileOperation.comparable` gives them, and then by identity with
    /// `sourceHolding`, which catches a destination reached through a link. Copies, duplicates and
    /// moves to another volume read the volumes involved with `volumeOf` and pre-scan each item
    /// with `measure`. Copies and moves look for each item's name in the destination folder
    /// with `inspect`, top-level items only, and inspect the source of each that is there. An
    /// undo inspects each step's source, destination and destination folder, reads with
    /// `identify` the identity of each source the record has one for, reads the volumes of its
    /// moves and of the copies it makes again, and pre-scans what it copies. Where two of its
    /// paths differ only by case, it reads the volume they are on and, with `isCaseSensitive`,
    /// whether it tells them apart. A tag toggle reads each item's tags with `readTags`, and an
    /// undo each tagged item's, which must be the entries the record left. Nothing else reads
    /// the file system. Blocks while it reads, so it runs on a `BlockingCallThread`.
    ///
    /// `copies` is called once the volumes show the operation copies, before any pre-scan, so
    /// an undo pressed meanwhile doesn't wait for it.
    ///
    /// - Throws: `OperationState.Refusal`, or `CancellationError` once `isCancelled` returns true.
    static func make(
        for operation: FileOperation,
        volumeOf: (String) throws(ListingError) -> VolumeIdentity,
        isCaseSensitive: (VolumeIdentity) throws(ListingError) -> Bool,
        measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        inspect: (String) throws(FileOperationError) -> ConflictRequest.Item?,
        identify: FileOperationQueue.Identifier,
        sourceHolding: (String, [String]) throws(FileOperationError) -> String?,
        readTags: (String) throws(FileOperationError) -> [String] = FinderTags.entries(at:),
        isCancelled: @escaping () -> Bool,
        copies: () -> Void
    ) throws -> OperationPlan {
        switch operation {
        case .copy(let sources, let folder), .move(let sources, let folder):
            if let source = FileOperation.source(holding: folder, among: sources) {
                throw OperationState.Refusal.intoItself(source: source)
            }
            let holder: String?
            do {
                holder = try sourceHolding(folder, sources)
            } catch {
                return OperationPlan(items: [], lane: nil, failures: [error])
            }
            if let holder { throw OperationState.Refusal.intoItself(source: holder) }
            let isMove = if case .move = operation { true } else { false }
            return try transfer(
                sources, into: folder, isMove: isMove, volumeOf: volumeOf, measure: measure,
                inspect: inspect, isCancelled: isCancelled, copies: copies)
        case .duplicate(let sources):
            guard let first = sources.first else { return empty }
            let parent = parentPath(of: first)
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
        case .toggleTag(let tag, let paths):
            var items: [Item] = []
            var failures: [FileOperationError] = []
            var everyItemHasIt = true
            for path in paths {
                if isCancelled() { throw CancellationError() }
                do throws(FileOperationError) {
                    let names = try readTags(path).map(FinderTags.name(of:))
                    if !names.contains(tag.name) { everyItemHasIt = false }
                    items.append(
                        Item(
                            source: path, destination: nil, size: nil, crossesVolumes: false,
                            conflict: nil))
                } catch {
                    failures.append(error)
                }
            }
            var plan = OperationPlan(items: items, lane: nil, failures: failures)
            plan.addsTag = !everyItemHasIt
            return plan
        case .receive:
            preconditionFailure("\(operation) is reported, never planned")
        case .newFolder(let folder):
            return OperationPlan(
                items: [
                    Item(
                        source: folder, destination: nil, size: nil, crossesVolumes: false,
                        conflict: nil)
                ], lane: nil, failures: [])
        case .undo(let record, _, _):
            return try undoing(
                FileOperation.steps(undoing: record), identities: record.identities,
                volumeOf: volumeOf, isCaseSensitive: isCaseSensitive, measure: measure,
                inspect: inspect, identify: identify, readTags: readTags,
                isCancelled: isCancelled, copies: copies)
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
        isCancelled: @escaping () -> Bool, copies: () -> Void
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
                let parent = parentPath(of: source)
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
                copies()
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
    /// undo waits in the lane of the first such destination's volume. A put back is a rename,
    /// so one whose Trash is on another volume than its folder fails (`crossVolume`), and
    /// nothing is changed. A tagged item's tags, read with `readTags`, must be the ones its
    /// change left (`tagsChanged`), so an undo never overwrites tags changed since.
    ///
    /// Two paths that differ only by case name one place on a volume that doesn't tell case
    /// apart, as APFS and HFS+ by default, and two on one that does; the volume is read only
    /// for such a pair, once per folder and once per volume.
    private static func undoing(
        _ steps: [FileOperation.UndoStep], identities: [String: OperationRecord.ItemIdentity],
        volumeOf: (String) throws(ListingError) -> VolumeIdentity,
        isCaseSensitive: (VolumeIdentity) throws(ListingError) -> Bool,
        measure: (String, () -> Bool) throws -> TreeSizeWalker.Total,
        inspect: (String) throws(FileOperationError) -> ConflictRequest.Item?,
        identify: FileOperationQueue.Identifier,
        readTags: (String) throws(FileOperationError) -> [String],
        isCancelled: @escaping () -> Bool, copies: () -> Void
    ) throws -> OperationPlan {
        var folderVolumes: [String: Result<VolumeIdentity, ListingError>] = [:]
        func volume(ofFolder folder: String) throws(ListingError) -> VolumeIdentity {
            let volume =
                folderVolumes[folder] ?? Result { () throws(ListingError) in try volumeOf(folder) }
            folderVolumes[folder] = volume
            return try volume.get()
        }
        var caseSensitivity: [VolumeIdentity: Result<Bool, ListingError>] = [:]
        var unreadCaseSensitivity: [String: ListingError] = [:]
        /// Whether `path` and `other` name one place: spelled alike, or differing only by case
        /// on a volume that doesn't tell case apart. That is the volume of the folder holding
        /// the first name that differs or, where no folder is there (`ENOENT`, or `ENOTDIR`
        /// through a file), of the nearest folder above it that is there. Where the volume, or
        /// whether it tells case apart, can't be read, the pair is one place, as on most
        /// volumes, and the error is kept for the log: a check that failed on it would drop
        /// the undo of a rename that changed only case.
        func isSamePlace(_ path: String, _ other: String) -> Bool {
            let spelled = FileOperation.comparable(path, foldsCase: false)
            let otherSpelled = FileOperation.comparable(other, foldsCase: false)
            if spelled == otherSpelled { return true }
            guard FileOperation.comparable(path) == FileOperation.comparable(other) else {
                return false
            }
            let names = pathComponents(spelled)
            let otherNames = pathComponents(otherSpelled)
            let differing = zip(names, otherNames).prefix { $0 == $1 }.count
            var folder = join("/", names.prefix(differing).joined(separator: "/"))
            do throws(ListingError) {
                var found: VolumeIdentity
                while true {
                    do throws(ListingError) {
                        found = try volume(ofFolder: folder)
                        break
                    } catch let error
                        where [ENOENT, ENOTDIR].contains(error.code)
                        && parentPath(of: folder) != folder
                    {
                        folder = parentPath(of: folder)
                    }
                }
                let sensitive =
                    caseSensitivity[found]
                    ?? Result { () throws(ListingError) in try isCaseSensitive(found) }
                caseSensitivity[found] = sensitive
                return try !sensitive.get()
            } catch {
                unreadCaseSensitivity[error.path] = error
                return true
            }
        }
        // What the earlier steps leave at each path they touch: by comparable path, each
        // spelling with whether it holds an item, the latest last.
        var after: [String: [(path: String, isTaken: Bool)]] = [:]
        func leave(_ path: String, isTaken: Bool) {
            let spelled = FileOperation.comparable(path, foldsCase: false)
            after[FileOperation.comparable(path), default: []].removeAll {
                FileOperation.comparable($0.path, foldsCase: false) == spelled
            }
            after[FileOperation.comparable(path), default: []].append((path, isTaken))
        }
        /// Whether `path` holds an item once the earlier steps have run, or nil when none
        /// touched it.
        func left(at path: String) -> Bool? {
            for entry in (after[FileOperation.comparable(path)] ?? []).reversed() {
                if isSamePlace(entry.path, path) { return entry.isTaken }
            }
            return nil
        }
        func isTaken(_ path: String) throws(FileOperationError) -> Bool {
            if let taken = left(at: path) { return taken }
            return try inspect(path) != nil
        }
        // The steps' paths by comparable path, so a missing folder that is one of them is
        // named as its step names it.
        var stepPaths: [String: [String]] = [:]
        for path in steps.flatMap({ [$0.source, $0.destination].compactMap { $0 } }) {
            stepPaths[FileOperation.comparable(path), default: []].append(path)
        }
        var failures: [FileOperationError] = []
        // The paths `gone` has named, so each is named once.
        var named: Set<String> = []
        /// Records `path` as gone or, when its folder is gone too, the outermost folder that
        /// is, as a drive that isn't mounted: the history keeps an entry whose folder may come
        /// back, and drops one whose item left a folder that is still there. A folder that is
        /// one of the steps' items is named as the step names it, which is how
        /// `FileOperation.canClear` tells it from a folder outside them.
        func gone(_ path: String) throws(FileOperationError) {
            var missing = path
            while true {
                let folder = parentPath(of: missing)
                guard folder != missing, try !isTaken(folder) else { break }
                missing = folder
            }
            let spelled = FileOperation.comparable(missing, foldsCase: false)
            let spellings = stepPaths[FileOperation.comparable(missing)] ?? []
            if !spellings.contains(where: {
                FileOperation.comparable($0, foldsCase: false) == spelled
            }) {
                for item in spellings where isSamePlace(item, missing) {
                    missing = item
                    break
                }
            }
            if named.insert(missing).inserted {
                failures.append(
                    FileOperationError(reason: .sourceGone, path: missing, errno: ENOENT))
            }
        }
        for step in steps {
            if isCancelled() { throw CancellationError() }
            let source = step.source
            do throws(FileOperationError) {
                if let source {
                    if let taken = left(at: source) {
                        if !taken { try gone(source) }
                    } else if try inspect(source) == nil {
                        try gone(source)
                    } else if !step.readsSource,
                        let recorded = identities[
                            FileOperation.comparable(source, foldsCase: false)],
                        try identify(source) != recorded
                    {
                        // A copy made again copies whatever is at its source now, as a copy
                        // does, so only an item it would change is checked.
                        failures.append(
                            FileOperationError(reason: .notTheSameItem, path: source, errno: nil))
                    } else if case .retag(let path, let from, _) = step,
                        try readTags(path) != from
                    {
                        failures.append(
                            FileOperationError(reason: .tagsChanged, path: path, errno: nil))
                    }
                }
                if let destination = step.destination {
                    // A rename that changes only case, on a volume that doesn't tell case
                    // apart, finds the item itself at its destination.
                    var isItself = false
                    if let source { isItself = isSamePlace(source, destination) }
                    if !isItself, try isTaken(destination) {
                        failures.append(
                            FileOperationError(reason: .exists, path: destination, errno: EEXIST))
                    }
                    let folder = parentPath(of: destination)
                    if try !isTaken(folder) { try gone(folder) }
                }
            } catch {
                failures.append(error)
            }
            if let source, !step.readsSource { leave(source, isTaken: false) }
            if let destination = step.destination { leave(destination, isTaken: true) }
        }
        guard failures.isEmpty else {
            return OperationPlan(
                items: [], lane: nil, failures: failures,
                unreadCaseSensitivity: unreadCaseSensitivity)
        }
        func volume(of path: String) throws(ListingError) -> VolumeIdentity {
            try volume(ofFolder: parentPath(of: path))
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
            case .putBack(let url, let to):
                do throws(ListingError) {
                    if try volume(of: url.path) != volume(of: to) {
                        failures.append(
                            FileOperationError(reason: .crossVolume, path: url.path, errno: EXDEV))
                        continue
                    }
                } catch {
                    failures.append(failure(error))
                    continue
                }
            case .trash, .unmake, .make, .retag:
                break
            }
            if let copied {
                copies()
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
            return OperationPlan(
                items: [], lane: nil, failures: failures,
                unreadCaseSensitivity: unreadCaseSensitivity)
        }
        return OperationPlan(
            items: items, lane: lane, failures: [], unreadCaseSensitivity: unreadCaseSensitivity)
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

    /// An identifier for one operation, or nil when nothing is at the path. On a volume with
    /// `VOL_CAP_FMT_PERSISTENTOBJECTIDS` and a UUID: the UUID and the inode. Elsewhere, as on
    /// FAT and exFAT, which make inodes up, and shares without a UUID: a fingerprint from the
    /// same `lstat` (`identity(of:volume:)`). What each volume reports is read once per
    /// operation, by `st_dev`, which holds while the operation runs. Symlinks aren't followed.
    /// Blocks the calling thread, which must be a `BlockingCallThread`.
    static func identifier() -> FileOperationQueue.Identifier {
        let volumes = VolumeUUIDs()
        return { path throws(FileOperationError) in
            BlockingCallThread.requireCurrent()
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw FileOperationError(errno: errno, path: path)
            }
            return identity(of: info, volume: try volumes.uuid(of: info.st_dev, holding: path))
        }
    }

    /// The identity `info`, an `lstat` of an item, gives on `volume`, the UUID of a volume
    /// whose IDs persist, or nil for one whose don't.
    static func identity(of info: stat, volume: String?) -> OperationRecord.ItemIdentity {
        if let volume { return .persistent(volume: volume, inode: UInt64(info.st_ino)) }
        let type = UInt16(info.st_mode & S_IFMT)
        let born = nanoseconds(info.st_birthtimespec)
        // Zero is what a file system without birth times reports.
        guard born == 0 else { return .fingerprint(type: type, born: born) }
        return .fingerprintWithoutBirthTime(
            type: type, modified: nanoseconds(info.st_mtimespec), size: Int64(info.st_size))
    }

    private static func nanoseconds(_ time: timespec) -> Int64 {
        Int64(time.tv_sec) * 1_000_000_000 + Int64(time.tv_nsec)
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

    /// The stamp of the item at `path` and, for a folder, of every item under it, read with
    /// `fts` and keyed by path, or nil when nothing is at `path`. Symlinks aren't followed, and
    /// a folder another volume is mounted on is read but not entered. An item that can't be
    /// read, or a folder that can't be listed, is kept with its errno, so the same failure
    /// twice gives the same stamp. Blocks the calling thread, which must be a
    /// `BlockingCallThread`.
    ///
    /// - Throws: `FileOperationError` when the walk can't start or stops on an error, and
    ///   `CancellationError` once `isCancelled`, asked first and before each item, returns true.
    static func stamp(_ path: String, isCancelled: () -> Bool) throws
        -> FileOperationQueue.SourceStamp?
    {
        BlockingCallThread.requireCurrent()
        if isCancelled() { throw CancellationError() }
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw FileOperationError(errno: errno, path: path)
        }
        guard info.st_mode & S_IFMT == S_IFDIR else {
            return FileOperationQueue.SourceStamp(items: [path: stamp(of: info)])
        }
        guard let root = strdup(path) else { throw FileOperationError(errno: ENOMEM, path: path) }
        defer { free(root) }
        var roots: [UnsafeMutablePointer<CChar>?] = [root, nil]
        guard let tree = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw FileOperationError(errno: errno, path: path)
        }
        defer { fts_close(tree) }
        var items: [String: FileOperationQueue.SourceStamp.Item] = [:]
        while true {
            if isCancelled() { throw CancellationError() }
            // `fts_read` returns nil both at the end and on an error; only errno tells them apart.
            errno = 0
            guard let entry = fts_read(tree) else {
                if errno != 0 { throw FileOperationError(errno: errno, path: path) }
                return FileOperationQueue.SourceStamp(items: items)
            }
            let item = entry.pointee
            switch Int32(item.fts_info) {
            // A folder is stamped on the way in; this is the way out.
            case FTS_DP: continue
            case FTS_DNR, FTS_ERR, FTS_NS:
                items[String(cString: item.fts_path)] = .unread(errno: item.fts_errno)
            default: items[String(cString: item.fts_path)] = stamp(of: item.fts_statp.pointee)
            }
        }
    }

    private static func stamp(of info: stat) -> FileOperationQueue.SourceStamp.Item {
        .read(
            device: info.st_dev, inode: UInt64(info.st_ino), type: UInt16(info.st_mode & S_IFMT),
            size: Int64(info.st_size), modified: nanoseconds(info.st_mtimespec))
    }

    /// The first of `sources` that the folder at `folder` is or is inside, judged by identity:
    /// the device and inode of the folder and of each folder above it, up to the root, against
    /// each source's. Catches what `FileOperation.source(holding:among:)` can't see from the
    /// paths, such as a destination reached through a symlink into a source. A source that is
    /// a symlink isn't followed, since a copy of it copies the link. A source that can't be
    /// read is passed over here; its pre-scan fails it. Blocks the calling thread, which must
    /// be a `BlockingCallThread`.
    ///
    /// - Throws: `FileOperationError` when `folder` or a folder above it can't be read.
    static func source(holding folder: String, among sources: [String])
        throws(FileOperationError) -> String?
    {
        BlockingCallThread.requireCurrent()
        struct Identity: Hashable {
            let device: dev_t
            let inode: ino_t
        }
        guard var path = resolvedPath(folder) else {
            throw FileOperationError(errno: errno, path: folder)
        }
        var above: Set<Identity> = []
        while true {
            var info = stat()
            guard lstat(path, &info) == 0 else {
                throw FileOperationError(errno: errno, path: path)
            }
            above.insert(Identity(device: info.st_dev, inode: info.st_ino))
            if path == "/" { break }
            path = parentPath(of: path)
        }
        return sources.first { source in
            var info = stat()
            guard lstat(source, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return false }
            return above.contains(Identity(device: info.st_dev, inode: info.st_ino))
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
