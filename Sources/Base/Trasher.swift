import Darwin
import Foundation

/// Moves items to the Trash of their volume, one at a time, and reports where each one went so
/// Undo can move it back. See docs/decisions/0059-trash.md.
public struct Trasher: Sendable {
    /// Moves the item at a URL to the Trash and returns its URL there.
    public typealias TrashCall = @Sendable (URL) throws -> URL

    private let trashCall: TrashCall

    /// `trashCall` is `FileManager.trashItem` unless a test injects a failure.
    public init(trashCall: @escaping TrashCall = Trasher.trashItem) {
        self.trashCall = trashCall
    }

    /// Moves the item at `path` to its volume's Trash and returns its URL there. A volume without
    /// a trash throws `noTrash` and leaves the item where it is; deleting it instead is the
    /// caller's question to ask, and `deletePermanently` its answer. Blocks the calling thread;
    /// call it off the main thread.
    public func trash(_ path: String) throws(FileOperationError) -> URL {
        precondition(
            !Thread.isMainThread, "Trasher does file-system I/O; call it off the main thread")
        do {
            return try trashCall(URL(fileURLWithPath: path))
        } catch {
            throw Self.operationError(error, path: path)
        }
    }

    /// Whether the volume holding `folder` has a Trash, found by trashing an empty file made in
    /// `folder` for the purpose and deleting it from the Trash: no API answers it, and
    /// `FileManager`'s trash folder lookup fails on volumes that have one. The answer is the
    /// one `trash` would give, so a caller can ask before it changes anything. Leaves nothing in
    /// `folder` or the Trash. Blocks the calling thread; call it off the main thread.
    public func hasTrash(in folder: String) throws(FileOperationError) -> Bool {
        precondition(
            !Thread.isMainThread, "Trasher does file-system I/O; call it off the main thread")
        let probe = folder + "/.searcher-trash-probe-" + UUID().uuidString
        let descriptor = open(probe, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else { throw FileOperationError(errno: errno, path: probe) }
        close(descriptor)
        let trashed: URL
        do {
            trashed = try trash(probe)
        } catch let error where error.reason == .noTrash {
            try Self.deletePermanently(probe)
            return false
        } catch {
            try Self.deletePermanently(probe)
            throw error
        }
        try Self.deletePermanently(trashed.path)
        return true
    }

    /// Deletes the item at `path`, and everything in it if it is a folder, without the Trash.
    /// Call it only after the user has answered a delete-immediately question for this item, or
    /// on the source of a move to another volume once its copy is complete. Blocks the calling
    /// thread; call it off the main thread.
    public static func deletePermanently(_ path: String) throws(FileOperationError) {
        precondition(
            !Thread.isMainThread, "Trasher does file-system I/O; call it off the main thread")
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch {
            throw operationError(error, path: path)
        }
    }

    /// `FileManager.trashItem`. It returned a result URL for every item in spike S7's runs, so a
    /// missing one is an error rather than a success with nowhere to undo from.
    public static let trashItem: TrashCall = { url in
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else {
            throw FileOperationError(reason: .other, path: url.path, errno: nil)
        }
        return result as URL
    }

    /// The `FileOperationError` for an error `FileManager` threw on `path`. Its errors carry a
    /// POSIX error when a system call failed; `trashItem`'s carry an OSStatus instead, so those
    /// are read from the Cocoa code.
    private static func operationError(_ error: any Error, path: String) -> FileOperationError {
        if let error = error as? FileOperationError { return error }
        let error = error as NSError
        if error.domain == NSPOSIXErrorDomain {
            return FileOperationError(errno: Int32(error.code), path: path)
        }
        guard error.domain == NSCocoaErrorDomain else {
            return FileOperationError(reason: .other, path: path, errno: nil)
        }
        // Where the volume has no trash. Not yet seen from a real volume: see 0059's SMB and
        // exFAT runs.
        if error.code == CocoaError.featureUnsupported.rawValue {
            return FileOperationError(reason: .noTrash, path: path, errno: nil)
        }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSPOSIXErrorDomain
        {
            return FileOperationError(errno: Int32(underlying.code), path: path)
        }
        let reason: FileOperationError.Reason =
            switch CocoaError.Code(rawValue: error.code) {
            case .fileNoSuchFile, .fileReadNoSuchFile: .sourceGone
            case .fileReadNoPermission, .fileWriteNoPermission, .fileWriteVolumeReadOnly:
                .permissionDenied
            case .fileWriteOutOfSpace: .noSpace
            default: .other
            }
        return FileOperationError(reason: reason, path: path, errno: nil)
    }
}
