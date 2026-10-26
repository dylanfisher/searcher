import Base
import CoreGraphics
import Foundation

/// Makes the thumbnails that list rows, column rows and the column preview show in place of a
/// file's type icon, and keeps the latest in a `ThumbnailCache`. A request names the volume its
/// folder's load read with `statfs`, so a folder reached through a link onto a share is on the
/// share. A file on a network volume gets none: one costs 85 ms per audio file over SMB. On a
/// local volume at most `ListingService.mostReads(on:)` are made at once, apart from the loads'
/// and the info reads' slots, each started on a `BlockingCallThread`; the rest wait without a
/// thread, and one that takes `giveUp` is cancelled and frees its slot
/// (docs/decisions/0004-listing-view.md, docs/decisions/0038-slow-volumes.md,
/// docs/decisions/0102-thumbnails.md).
public final class ThumbnailService: Sendable {
    /// Pixels per point of every thumbnail made. Retina's; a 1x display draws it scaled down,
    /// which costs a 16-point row 3 KB more than its own scale would.
    public static let scale = 2.0
    /// The cache's limit: about 7,000 row thumbnails or 120 preview ones.
    public static let mostCachedBytes = 32 << 20
    /// How long a thumbnail may take before it is cancelled, its slot freed and the file kept as
    /// having none. A local one takes 1–112 ms; one that hasn't come in this long is a broken
    /// file, a stalled disk or a Quick Look that stopped answering, and four of them would
    /// otherwise stop every thumbnail on the volume.
    public static let giveUp: Duration = .seconds(5)

    private let maker: any ThumbnailMaking
    private let cache: ThumbnailCache
    /// Starts a wait of the given length on the service's clock, taking the deadline at once, and
    /// returns the wait.
    private let startWait: @Sendable (Duration) -> @Sendable () async throws -> Void
    /// The requests making a thumbnail and waiting for a slot, per volume.
    let calls = InfoReads()

    public init<C: Clock<Duration>>(
        maker: any ThumbnailMaking = QuickLookThumbnailer(), clock: C = ContinuousClock(),
        mostCachedBytes: Int = ThumbnailService.mostCachedBytes
    ) {
        self.maker = maker
        cache = ThumbnailCache(mostBytes: mostCachedBytes)
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    /// Whether `entry`, of `kind`, may show a thumbnail: a regular file whose contents are on
    /// this Mac, since making one reads them (docs/decisions/0030-not-downloaded-badge.md), and
    /// that isn't text, which keeps its type icon as Finder shows it. Folders, packages and links
    /// keep their icons.
    public static func shows(_ entry: DirectoryEntry, kind: EntryKind) -> Bool {
        entry.type == .regular && !entry.isDataless && !kind.isText
    }

    /// Whether files on `volume` get thumbnails: a local volume's do, a network volume's don't.
    public static func makes(on volume: VolumeIdentity) -> Bool {
        volume.kind == .local
    }

    /// The thumbnail kept of `entry`, the file at `path`, at `side` points: nil when none is
    /// kept, `.some(nil)` when it was asked for and the file has none. Reads no file.
    public func cached(at path: String, entry: DirectoryEntry, side: Double) -> CGImage?? {
        cache.value(for: Self.key(path, entry, side))
    }

    /// The largest thumbnail kept of `entry`, the file at `path`, smaller than `side` points,
    /// such as a row's, for the preview to show scaled while its own is made; nil when none is
    /// kept. Reads no file.
    public func cachedSmaller(at path: String, entry: DirectoryEntry, than side: Double)
        -> CGImage?
    {
        cache.largestSmaller(than: Self.key(path, entry, side))
    }

    /// The thumbnail of `entry`, the file at `path` on `volume`, at `side` points, from the cache
    /// or made and kept there; nil when the file has none, took `giveUp`, or is on a network
    /// volume. A request `first` waits ahead of the others for its volume's slot, as the
    /// preview's does ahead of rows'. Throws when the calling task is cancelled before the
    /// thumbnail starts being made; one already being made is still kept.
    public func thumbnail(
        at path: String, entry: DirectoryEntry, side: Double, on volume: VolumeIdentity,
        first: Bool = false
    ) async throws(CancellationError) -> CGImage? {
        let key = Self.key(path, entry, side)
        if let kept = cache.value(for: key) { return kept }
        guard Self.makes(on: volume) else { return nil }
        guard !Task.isCancelled else { throw CancellationError() }
        let calls = calls
        let cache = cache
        let maker = maker
        let startWait = startWait
        let id = calls.makeID()
        // Nil when cancelled before it started; otherwise the thumbnail, nil if there is none.
        let outcome: CGImage?? = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<CGImage??, Never>) in
                let making = Making()
                // Runs once the volume has a slot, always on a `BlockingCallThread`: a slot that
                // frees hands it one, and a slot free now starts one from the caller's thread.
                let start: @Sendable () -> Void = {
                    let wait = startWait(Self.giveUp)
                    let stop = maker.makeThumbnail(at: path, side: side, scale: Self.scale) {
                        image in
                        guard making.end() else { return }
                        cache.store(image, for: key)
                        calls.finish(id, on: volume)
                        continuation.resume(returning: .some(image))
                    }
                    making.watch(
                        Task {
                            do {
                                try await wait()
                            } catch {
                                // Cancelled: the thumbnail came in time.
                                return
                            }
                            guard making.end() else { return }
                            stop()
                            cache.store(nil, for: key)
                            calls.finish(id, on: volume)
                            continuation.resume(returning: .some(nil))
                        })
                }
                calls.enter(
                    id, on: volume, first: first,
                    cancelled: { continuation.resume(returning: .none) }
                ) {
                    if BlockingCallThread.isCurrent {
                        start()
                    } else {
                        BlockingCallThread.start(start)
                    }
                }
            }
        } onCancel: {
            calls.cancel(id)
        }
        // A cancel that landed after the request finished left the id behind as cancelled early;
        // no cancel can land after this.
        calls.forget(id)
        guard let outcome else { throw CancellationError() }
        return outcome
    }

    private static func key(_ path: String, _ entry: DirectoryEntry, _ side: Double)
        -> ThumbnailCache.Key
    {
        ThumbnailCache.Key(
            path: path, modified: entry.modified, size: entry.size,
            pixels: Int((side * scale).rounded()))
    }

    /// One thumbnail being made: whichever of Quick Look's answer and the `giveUp` wait comes
    /// first ends it, and the other does nothing.
    private final class Making: @unchecked Sendable {
        // `lock` guards everything below.
        private let lock = NSLock()
        private var ended = false
        private var watchdog: Task<Void, Never>?

        /// Ends the making; false when it had ended already. Stops the `giveUp` wait.
        func end() -> Bool {
            let stopped: Task<Void, Never>?? = lock.withLock {
                guard !ended else { return nil }
                ended = true
                defer { watchdog = nil }
                return .some(watchdog)
            }
            guard let stopped else { return false }
            stopped?.cancel()
            return true
        }

        /// Keeps `task`, the `giveUp` wait, to stop when the making ends; stops it at once if the
        /// making ended already, as it does when the answer came before the wait started.
        func watch(_ task: Task<Void, Never>) {
            let ended = lock.withLock {
                if !self.ended { watchdog = task }
                return self.ended
            }
            if ended { task.cancel() }
        }
    }
}
