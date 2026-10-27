import Foundation

/// Replaces a file in one step: the data goes to a temporary file beside it, which is renamed over
/// the old one, so a reader sees either the previous file or the new one, never a partial write.
/// The temporary file is synced to the disk before the rename, so a power loss after the rename
/// can't leave an empty file in place of the old one.
public enum AtomicWrite {
    /// Writes `data` to `url`. `beforeRename` runs between the write and the rename; tests use it
    /// to interrupt a write. If anything throws, the temporary file is removed and `url` is left
    /// as it was. Call it off the main thread.
    public static func write(
        _ data: Data, to url: URL, beforeRename: () throws -> Void = {}
    ) throws {
        try write(data, to: url, synchronize: { try $0.synchronize() }, beforeRename: beforeRename)
    }

    /// Writes `data` to a new file at `url`, as `write(_:to:beforeRename:)` does, but never over
    /// a file that is there: the rename is `renamex_np` with `RENAME_EXCL`, so a file made at
    /// `url` after any check the caller ran is kept too.
    ///
    /// - Throws: `POSIXError(.EEXIST)` when `url` exists, which is left as it was.
    public static func create(_ data: Data, at url: URL) throws {
        try write(
            data, to: url, synchronize: { try $0.synchronize() }, beforeRename: {},
            exclusive: true)
    }

    /// `write(_:to:beforeRename:)`, syncing the temporary file's open handle with `synchronize`;
    /// tests pass one that records the call or fails.
    /// With `exclusive`, the rename fails rather than replace a file at `url`.
    static func write(
        _ data: Data, to url: URL, synchronize: (FileHandle) throws -> Void,
        beforeRename: () throws -> Void, exclusive: Bool = false
    ) throws {
        preconditionOffMain("AtomicWrite")
        // In the same folder, so the rename stays on one volume and can't turn into a copy.
        let partial = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent)\(partialMarker)\(UUID().uuidString)")
        do {
            try data.write(to: partial, options: .withoutOverwriting)
            // fsync hands the data to the drive before the rename is made, so the rename can't
            // reach the disk ahead of it. F_FULLFSYNC, which also empties the drive's own cache,
            // was left out for its cost (0078-workspace-store.md).
            let handle = try FileHandle(forWritingTo: partial)
            let synced = Result { try synchronize(handle) }
            try handle.close()
            try synced.get()
            try beforeRename()
            let renamed =
                exclusive
                ? renamex_np(partial.path, url.path, UInt32(RENAME_EXCL))
                : rename(partial.path, url.path)
            guard renamed == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            if FileManager.default.fileExists(atPath: partial.path) {
                do {
                    try FileManager.default.removeItem(at: partial)
                } catch let cleanup {
                    throw Failed(
                        description: "\(error); removing \(partial.path) then failed: \(cleanup)")
                }
            }
            throw error
        }
    }

    /// Whether `name` is one of the temporary files `write` makes. A crash between its write and
    /// its rename leaves one behind, which a store can delete.
    public static func isPartial(_ name: String) -> Bool {
        guard name.hasPrefix("."), let marker = name.range(of: partialMarker, options: .backwards)
        else { return false }
        return marker.lowerBound > name.index(after: name.startIndex)
            && UUID(uuidString: String(name[marker.upperBound...])) != nil
    }

    private static let partialMarker = ".partial-"

    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }
}
