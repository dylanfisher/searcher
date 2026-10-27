import CoreServices
import Darwin
import Foundation

/// One change FSEvents reported: the path it happened to, and what kind of change it was. A path
/// can carry several flags, and events for one path can coalesce, so `created` and `removed` can be
/// set together; read the file system for the current state.
public struct FileEvent: Equatable, Sendable {
    public struct Flags: OptionSet, Sendable {
        public let rawValue: UInt32

        public init(rawValue: UInt32) {
            self.rawValue = rawValue
        }

        public static let created = Flags(rawValue: 1 << 0)
        public static let removed = Flags(rawValue: 1 << 1)
        public static let renamed = Flags(rawValue: 1 << 2)
        public static let modified = Flags(rawValue: 1 << 3)
        /// Events were dropped or coalesced into a folder, so the paths reported aren't all of
        /// them. The folder at the event's path has to be read again, with everything under it.
        public static let mustRescan = Flags(rawValue: 1 << 4)
        /// The watched folder itself, or a folder on the path to it, was moved, deleted or
        /// replaced. The event's path is the watched path.
        public static let rootChanged = Flags(rawValue: 1 << 5)
        /// Set with `mustRescan` when the stream or the kernel dropped events: every folder the
        /// stream watches has to be read again, whatever path the event names.
        public static let dropped = Flags(rawValue: 1 << 6)
    }

    public let path: String
    public let flags: Flags

    public init(path: String, flags: Flags) {
        self.path = path
        self.flags = flags
    }

    init(path: String, fsEventFlags: FSEventStreamEventFlags) {
        var flags: Flags = []
        func add(_ flag: Flags, if fsFlag: Int) {
            if fsEventFlags & FSEventStreamEventFlags(fsFlag) != 0 { flags.insert(flag) }
        }
        add(.created, if: kFSEventStreamEventFlagItemCreated)
        add(.removed, if: kFSEventStreamEventFlagItemRemoved)
        add(.renamed, if: kFSEventStreamEventFlagItemRenamed)
        add(
            .modified,
            if: kFSEventStreamEventFlagItemModified | kFSEventStreamEventFlagItemInodeMetaMod
                | kFSEventStreamEventFlagItemChangeOwner | kFSEventStreamEventFlagItemXattrMod
                | kFSEventStreamEventFlagItemFinderInfoMod)
        add(
            .mustRescan,
            if: kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped)
        add(.dropped, if: kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped)
        add(.rootChanged, if: kFSEventStreamEventFlagRootChanged)
        self.init(path: path, flags: flags)
    }
}

/// Reports file-level changes under a folder with one FSEvents stream, which costs no file
/// descriptor. It sees changes made on this machine only: on a network volume changes made by
/// other machines never arrive, which is why those folders use `VnodeWatch`. See
/// docs/decisions/0005-change-watching.md.
public final class FileEventStream: @unchecked Sendable {
    /// What the C callback reaches through its context pointer.
    private final class Receiver: @unchecked Sendable {
        let onEvents: @Sendable ([FileEvent]) -> Void
        let lock = NSLock()
        var stopped = false

        init(onEvents: @escaping @Sendable ([FileEvent]) -> Void) {
            self.onEvents = onEvents
        }

        func deliver(_ events: [FileEvent]) {
            lock.lock()
            let live = !stopped
            lock.unlock()
            if live { onEvents(events) }
        }
    }

    private let stream: FSEventStreamRef
    private let receiver: Receiver
    private let lock = NSLock()
    private var stopped = false

    /// Starts watching `path` and everything under it. `onEvents` runs on a serial queue with each
    /// batch of events, in order. Events are batched for `latency` seconds. Call it off the main
    /// thread.
    ///
    /// - Throws: `ListingError` with `EIO` if the system won't start the stream, which reports no
    ///   errno.
    public init(
        path: String, latency: TimeInterval = 0.1,
        onEvents: @escaping @Sendable ([FileEvent]) -> Void
    ) throws {
        let receiver = Receiver(onEvents: onEvents)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passRetained(receiver).toOpaque(),
            retain: nil, release: { Unmanaged<Receiver>.fromOpaque($0!).release() },
            copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let receiver = Unmanaged<Receiver>.fromOpaque(info!).takeUnretainedValue()
            let paths = paths.assumingMemoryBound(to: UnsafePointer<CChar>.self)
            let events = (0..<count).map {
                FileEvent(path: String(cString: paths[$0]), fsEventFlags: flags[$0])
            }
            receiver.deliver(events)
        }
        // NoDefer delivers the first event of a quiet period at once, then batches the rest.
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot
                | kFSEventStreamCreateFlagNoDefer)
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, [path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else {
            // Creating the stream failed before it took ownership of the receiver.
            Unmanaged.passUnretained(receiver).release()
            throw ListingError(path: path, code: EIO)
        }
        FSEventStreamSetDispatchQueue(
            stream, DispatchQueue(label: "FileEventStream", qos: .userInitiated))
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw ListingError(path: path, code: EIO)
        }
        self.stream = stream
        self.receiver = receiver
    }

    /// Stops the stream. A batch already running may finish, and none starts after.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if stopped { return }
        stopped = true
        receiver.lock.lock()
        receiver.stopped = true
        receiver.lock.unlock()
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
