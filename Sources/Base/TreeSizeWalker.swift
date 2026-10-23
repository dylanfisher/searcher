import Darwin

/// Adds up the logical sizes of the regular files under a folder, and counts its entries other
/// than folders, reading each folder with `DirectoryLister`. Symlinks aren't followed, folders
/// on another volume or that another volume is mounted on aren't entered, and a file with
/// several hard links counts once per link, as `fts` counts them. A subfolder that can't be read
/// for lack of permission, whose path is too long, or whose listing isn't downloaded leaves the
/// total partial. Blocks the calling thread; see docs/decisions/0043-folder-sizes.md.
public struct TreeSizeWalker: Sendable {
    public struct Total: Equatable, Sendable {
        public let bytes: Int64
        /// Entries other than folders: files, symlinks and the rest, as `FileCopier` counts what
        /// it copies, so a copy's file count ends at this one.
        public let files: Int
        /// Some subfolder wasn't read, so `bytes` and `files` are lower bounds.
        public let isPartial: Bool

        public init(bytes: Int64, files: Int, isPartial: Bool) {
            self.bytes = bytes
            self.files = files
            self.isPartial = isPartial
        }
    }

    /// What a subfolder that fails to list does to the walk.
    enum SubfolderFailure: Equatable {
        /// Skipped, and the total is partial: its files are there but weren't counted.
        case partial
        /// Skipped: deleted or replaced since its parent was read, so nothing of it is there.
        case skipped
        /// The walk fails with the error, as for a share that stopped answering.
        case fatal
    }

    /// The running total, counted one batch at a time.
    struct Tally {
        private(set) var bytes: Int64 = 0
        private(set) var files = 0
        var isPartial = false

        /// Adds the regular files in `batch`, a batch of `folder`'s entries, and returns the
        /// subfolders to walk. A folder whose listing isn't downloaded isn't one of them: listing
        /// it would download it (docs/decisions/0030-not-downloaded-badge.md).
        mutating func count(_ batch: [DirectoryEntry], in folder: String) -> [String] {
            var subfolders: [String] = []
            for entry in batch {
                switch entry.type {
                case .regular:
                    guard let size = entry.size else {
                        preconditionFailure("the lister gave the file \(entry.name) no size")
                    }
                    bytes += size
                    files += 1
                case .directory where entry.isDataless:
                    isPartial = true
                case .directory:
                    subfolders.append(folder + "/" + entry.name)
                case .symbolicLink, .other:
                    files += 1
                }
            }
            return subfolders
        }
    }

    public let lister: DirectoryLister

    public init(lister: DirectoryLister = DirectoryLister()) {
        self.lister = lister
    }

    /// Walks the folder at `path`. `isCancelled` is asked before each folder is opened and before
    /// each buffer of entries is counted, so a cancelled walk reads at most one buffer more.
    ///
    /// - Throws: `CancellationError` once `isCancelled` returns true. `ListingError` if `path`
    ///   can't be listed, or a subfolder fails as `failure(for:)` calls fatal.
    public func walk(_ path: String, isCancelled: () -> Bool = { false }) throws -> Total {
        let device = try lister.device(of: path)
        var tally = Tally()
        var folders = [path]
        while let folder = folders.popLast() {
            if isCancelled() { throw CancellationError() }
            do {
                _ = try lister.listWithoutMountPoints(folder, ifOnDevice: device) { batch in
                    if isCancelled() { throw CancellationError() }
                    folders += tally.count(batch, in: folder)
                }
            } catch let error as ListingError where folder != path {
                switch Self.failure(for: error) {
                case .partial: tally.isPartial = true
                case .skipped: break
                case .fatal: throw error
                }
            }
        }
        return Total(bytes: tally.bytes, files: tally.files, isPartial: tally.isPartial)
    }

    static func failure(for error: ListingError) -> SubfolderFailure {
        // The walker builds full paths, so a deep enough folder can't be named in one call.
        if error.code == ENAMETOOLONG { return .partial }
        return switch error.reason {
        case .permissionDenied, .privacyProtected: .partial
        case .notFound, .notADirectory: .skipped
        case .unreachable, .other: .fatal
        }
    }
}
