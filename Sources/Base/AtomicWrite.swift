import Foundation

/// Replaces a file in one step: the data goes to a temporary file beside it, which is renamed over
/// the old one, so a reader sees either the previous file or the new one, never a partial write.
public enum AtomicWrite {
    /// Writes `data` to `url`. `beforeRename` runs between the write and the rename; tests use it to
    /// interrupt a write. If anything throws, the temporary file is removed and `url` is left as it
    /// was. Call it off the main thread.
    public static func write(
        _ data: Data, to url: URL, beforeRename: () throws -> Void = {}
    ) throws {
        precondition(
            !Thread.isMainThread, "AtomicWrite does file-system I/O; call it off the main thread")
        // In the same folder, so the rename stays on one volume and can't turn into a copy.
        let partial = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try data.write(to: partial, options: .withoutOverwriting)
            try beforeRename()
            guard rename(partial.path, url.path) == 0 else {
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

    public struct Failed: Error, CustomStringConvertible {
        public let description: String
    }
}
