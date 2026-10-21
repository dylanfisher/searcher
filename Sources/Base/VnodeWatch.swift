import Darwin
import Dispatch
import Foundation

/// Calls a handler whenever a folder changes: an entry added, removed or renamed, or the folder
/// itself changed. It doesn't say which entry, so the caller re-lists. It holds one file
/// descriptor until `stop`. See docs/decisions/0005-change-watching.md.
public final class VnodeWatch: @unchecked Sendable {
    /// The watched descriptor, which is closed after `stop`.
    public let fileDescriptor: Int32

    private let source: any DispatchSourceFileSystemObject
    private let closed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    /// Opens `path` and starts watching it. `onChange` runs on a utility queue, one call at a
    /// time. Opening blocks on a network volume that has stopped answering, so call it off the main
    /// thread.
    public init(path: String, onChange: @escaping @Sendable () -> Void) throws {
        // O_EVTONLY opens for notifications only, so the watch doesn't block unmounting.
        let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor < 0 { throw ListingError(path: path, code: errno) }
        fileDescriptor = descriptor
        source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke],
            queue: DispatchQueue(label: "VnodeWatch", qos: .utility))
        let closed = closed
        source.setEventHandler(handler: onChange)
        // The descriptor must stay open until the source has finished with it.
        source.setCancelHandler {
            close(descriptor)
            closed.signal()
        }
        source.resume()
    }

    /// Stops the watch and closes the descriptor before returning. A call already running may
    /// finish, and none starts after. Don't call it from `onChange`.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return }
        stopped = true
        source.cancel()
        closed.wait()
    }

    deinit { stop() }
}
