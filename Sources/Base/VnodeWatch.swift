import Darwin
import Dispatch
import Foundation

/// Calls a handler whenever a folder changes: an entry added, removed or renamed, or the folder
/// itself changed. It doesn't say which entry, so the caller re-lists. It holds one file
/// descriptor until `stop`, or until the folder's volume is unmounted, which revokes the watch
/// and closes the descriptor. See docs/decisions/0005-change-watching.md.
public final class VnodeWatch: @unchecked Sendable {
    /// The watched descriptor, which is closed after `stop` or a revoke.
    public let fileDescriptor: Int32

    private let source: any DispatchSourceFileSystemObject
    private let closed = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var stopped = false

    /// Opens `path` and starts watching it. `onChange` and `onRevoke` run on a utility queue, one
    /// call at a time. When the folder's volume is unmounted, the watch ends by itself: it closes
    /// the descriptor, then calls `onRevoke` once, and calls nothing after. Opening blocks on a
    /// network volume that has stopped answering, so call it off the main thread.
    public init(
        path: String, onChange: @escaping @Sendable () -> Void,
        onRevoke: @escaping @Sendable () -> Void = {}
    ) throws {
        // O_EVTONLY opens for notifications only, so the watch doesn't block unmounting.
        let descriptor = open(path, O_EVTONLY | O_DIRECTORY | O_CLOEXEC)
        if descriptor < 0 { throw ListingError(path: path, code: errno) }
        fileDescriptor = descriptor
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .link, .delete, .rename, .revoke],
            queue: DispatchQueue(label: "VnodeWatch", qos: .utility))
        self.source = source
        let closed = closed
        let revoked = Revoked()
        source.setEventHandler {
            guard source.data.contains(.revoke) else { return onChange() }
            // The vnode is dead, so nothing more will arrive. The handlers run on one serial
            // queue, so the cancel handler sees `revoked`.
            revoked.value = true
            source.cancel()
        }
        // The descriptor must stay open until the source has finished with it.
        source.setCancelHandler {
            close(descriptor)
            closed.signal()
            if revoked.value { onRevoke() }
        }
        source.resume()
    }

    /// Stops the watch and closes the descriptor before returning, which a revoked watch has
    /// already done. A call already running may finish, and none starts after. Don't call it
    /// from `onChange` or `onRevoke`.
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

/// Whether a watch ended by being revoked. Only the watch's queue reads or writes it.
private final class Revoked: @unchecked Sendable {
    var value = false
}
