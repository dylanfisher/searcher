import Base
import Darwin
import Foundation

/// What a monitored folder asks of its pane.
public enum FolderChange: Equatable, Sendable {
    public enum Patch: Equatable, Sendable {
        /// The entry was added or changed.
        case update(DirectoryEntry)
        case remove(name: String)
    }

    /// Entries that changed, read from the file system when the event arrived. Apply them with
    /// `Listing.update` and `Listing.remove`.
    case patches([Patch])
    /// The folder has to be listed again: a network folder changed, or events were lost.
    case relist
}

/// Watches one folder and reports its changes. A folder on a local volume uses FSEvents and
/// reports the entries that changed; a folder on a network volume uses a vnode watch and reports
/// only that it changed. See docs/decisions/0005-change-watching.md.
public final class FolderMonitor: FolderMonitoring, @unchecked Sendable {
    public enum Watcher: Equatable, Sendable {
        case fileEvents
        case vnode
    }

    public let location: Location
    public let volume: VolumeKind
    public let watcher: Watcher

    private let lock = NSLock()
    private var stream: FileEventStream?
    private var vnode: VnodeWatch?

    /// Starts watching `location` as a folder on `volume`. `onChange` runs on a background queue,
    /// one call at a time, so a pane can patch a copy of its listing there; it isn't called on the
    /// main thread. A call already running when `stop` is called may finish.
    ///
    /// Opening the folder blocks on a network volume that has stopped answering, so this traps on
    /// the main thread.
    ///
    /// - Throws: `ListingError` if the folder can't be opened.
    public init(
        location: Location, volume: VolumeKind,
        onChange: @escaping @Sendable (FolderChange) -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        self.location = location
        self.volume = volume
        switch volume {
        case .local:
            watcher = .fileEvents
            // FSEvents reports resolved paths, so children are matched against the resolved folder.
            guard let resolved = realpath(location.path, nil) else {
                throw ListingError(path: location.path, code: errno)
            }
            defer { free(resolved) }
            let folder = String(cString: resolved)
            stream = try FileEventStream(path: folder) { events in
                if let change = Self.change(for: events, in: folder) { onChange(change) }
            }
        case .network:
            watcher = .vnode
            vnode = try VnodeWatch(path: location.path) { onChange(.relist) }
        }
    }

    /// Starts watching `location` on the kind of volume it is on. Reading the volume blocks on a
    /// share that has stopped answering, so this traps unless it runs on a `BlockingCallThread`.
    public convenience init(
        location: Location, onChange: @escaping @Sendable (FolderChange) -> Void
    ) throws {
        dispatchPrecondition(condition: .notOnQueue(.main))
        try self.init(
            location: location, volume: try VolumeIdentity(path: location.path).kind,
            onChange: onChange)
    }

    /// Stops watching and releases the watch's resources before returning.
    public func stop() {
        lock.lock()
        let stream = stream
        let vnode = vnode
        self.stream = nil
        self.vnode = nil
        lock.unlock()
        stream?.stop()
        vnode?.stop()
    }

    /// The vnode watch's file descriptor, while it is open.
    var vnodeDescriptor: Int32? {
        lock.lock()
        defer { lock.unlock() }
        return vnode?.fileDescriptor
    }

    /// The change a batch of events means for `folder`, or nil if none of them concerns its
    /// entries. Events name paths at any depth; only direct children matter, since a pane shows
    /// one level. Each named child is read once, as it is now, however many events it had, so a
    /// create followed by a delete patches as a delete.
    static func change(for events: [FileEvent], in folder: String) -> FolderChange? {
        if events.contains(where: { !$0.flags.isDisjoint(with: [.mustRescan, .rootChanged]) }) {
            return .relist
        }
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var names: [String] = []
        var seen: Set<String> = []
        for event in events where event.path.utf8.starts(with: prefix.utf8) {
            let name = String(Substring(event.path.utf8.dropFirst(prefix.utf8.count)))
            if !name.isEmpty, !name.contains("/"), seen.insert(name).inserted {
                names.append(name)
            }
        }
        var patches: [FolderChange.Patch] = []
        let lister = DirectoryLister()
        for name in names {
            do {
                if let entry = try lister.entry(named: name, inDirectory: folder) {
                    patches.append(.update(entry))
                } else {
                    patches.append(.remove(name: name))
                }
            } catch {
                // The re-list reads the folder again and reports whatever is wrong with it.
                return .relist
            }
        }
        return patches.isEmpty ? nil : .patches(patches)
    }

    deinit { stop() }
}
