import Base
import CoreGraphics
import Foundation

/// Makes the thumbnails that list rows, column rows and the column preview show in place of a
/// file's type icon, and keeps the latest in a `ThumbnailCache`. A request names the volume its
/// folder's load read with `statfs`, so a folder reached through a link onto a share is on the
/// share. Rows on a network volume get none: one costs 85 ms per audio file over SMB. The
/// preview's one file does, as Finder's does. A volume makes at most
/// `ListingService.mostReads(on:)` at once, one on a share, apart from the loads' and the info
/// reads' slots, each started on a `BlockingCallThread`; the rest wait without a thread, and one
/// that takes `giveUp`, or `shareGiveUp` on a share, is cancelled and frees its slot
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
    /// `giveUp` for the preview's thumbnail on a share, which only the preview asks for there:
    /// a large file such as a RAW photo can take longer than 5 s over SMB, and moving the
    /// selection on cancels it. One that takes this long isn't kept as having none, so selecting
    /// the file again asks again.
    public static let shareGiveUp: Duration = .seconds(30)

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

    /// Whether files on `volume` get thumbnails: a local volume's do. A network volume's rows
    /// don't, since a folder of them would read hundreds of files over the share; the preview's
    /// one file does, as Finder's does.
    public static func makes(on volume: VolumeIdentity, forPreview: Bool = false) -> Bool {
        volume.kind == .local || forPreview
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
    /// or made and kept there; nil when the file has none, took `giveUp` (`shareGiveUp` on a
    /// share), or is a row's on a network volume (`makes`). The preview's request,
    /// `forPreview`, waits ahead of rows' for its volume's slot. Throws when the calling task is
    /// cancelled before the thumbnail starts being made. One already being made is still kept
    /// on a local volume; on a network volume it is stopped and throws at once, and frees the
    /// share's one slot once Quick Look's call has returned, so a selection moved on through a
    /// folder on a share leaves only the latest file's request running or waiting.
    public func thumbnail(
        at path: String, entry: DirectoryEntry, side: Double, on volume: VolumeIdentity,
        forPreview: Bool = false
    ) async throws(CancellationError) -> CGImage? {
        let key = Self.key(path, entry, side)
        if let kept = cache.value(for: key) { return kept }
        guard Self.makes(on: volume, forPreview: forPreview) else { return nil }
        guard !Task.isCancelled else { throw CancellationError() }
        let calls = calls
        let cache = cache
        let maker = maker
        let startWait = startWait
        let id = calls.makeID()
        let making = Making(freeSlot: { calls.finish(id, on: volume) })
        let onShare = volume.kind == .network
        // Nil when cancelled before it ended; otherwise the thumbnail, nil if there is none.
        let outcome: CGImage?? = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<CGImage??, Never>) in
                making.wait { continuation.resume(returning: $0) }
                // Runs once the volume has a slot, always on a `BlockingCallThread`: a slot that
                // frees hands it one, and a slot free now starts one from the caller's thread.
                let start: @Sendable () -> Void = {
                    let wait = startWait(onShare ? Self.shareGiveUp : Self.giveUp)
                    let watchdog = Task {
                        do {
                            try await wait()
                        } catch {
                            // Cancelled: the thumbnail came in time, or the making ended.
                            return
                        }
                        // A share's is asked again when the file is selected again: it is slow,
                        // not broken, and the selection moving on is what bounds it.
                        making.abandon(with: .some(nil)) {
                            if !onShare { cache.store(nil, for: key) }
                        }
                    }
                    guard making.begin(watchdog: watchdog) else { return }
                    let stop = maker.makeThumbnail(at: path, side: side, scale: Self.scale) {
                        image in
                        making.answer(image) { cache.store(image, for: key) }
                    }
                    making.started(stop: stop)
                }
                calls.enter(
                    id, on: volume, first: forPreview,
                    cancelled: { making.abandon(with: .none) {} }
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
            // On a share, one being made is stopped, and the caller's wait ends at once even when
            // Quick Look's call hasn't returned; the slot is freed once it has.
            if onShare { making.abandon(with: .none) {} }
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

    /// One thumbnail request: whichever of Quick Look's answer, the give-up wait, a cancel while
    /// it waits for a slot and, on a share, a cancel while it is made comes first ends it, once,
    /// and the others do nothing. Ending it ends the caller's wait at once. Its slot is freed
    /// once Quick Look's call has returned, so a call that never returns holds its slot and
    /// thread, as a hung read holds its volume's (0038-slow-volumes.md).
    private final class Making: @unchecked Sendable {
        private let freeSlot: @Sendable () -> Void
        // `lock` guards everything below.
        private let lock = NSLock()
        private var resume: (@Sendable (CGImage??) -> Void)?
        private var ended = false
        private var hasStarted = false
        private var slotFreed = false
        private var stop: (@Sendable () -> Void)?
        private var watchdog: Task<Void, Never>?

        init(freeSlot: @escaping @Sendable () -> Void) {
            self.freeSlot = freeSlot
        }

        /// Keeps `resume`, which ends the caller's wait with the outcome; calls it at once with
        /// none when the request was cancelled before it got here.
        func wait(_ resume: @escaping @Sendable (CGImage??) -> Void) {
            let ended = lock.withLock {
                if !self.ended { self.resume = resume }
                return self.ended
            }
            if ended { resume(.none) }
        }

        /// Keeps `watchdog`, the give-up wait, and returns whether the making may start: false,
        /// with the wait stopped and the slot freed, when it was cancelled before its thread
        /// started it.
        func begin(watchdog: Task<Void, Never>) -> Bool {
            let begins = lock.withLock {
                if !ended { self.watchdog = watchdog }
                return !ended
            }
            if !begins {
                watchdog.cancel()
                releaseSlot()
            }
            return begins
        }

        /// Quick Look's call returned `stop`. A making given up or cancelled while the call ran
        /// is stopped now and frees its slot.
        func started(stop: @escaping @Sendable () -> Void) {
            let endedMeanwhile = lock.withLock {
                hasStarted = true
                self.stop = stop
                return ended && !slotFreed
            }
            if endedMeanwhile {
                stop()
                releaseSlot()
            }
        }

        /// Quick Look answered: unless the making ended already, runs `keep`, frees the slot and
        /// ends the caller's wait with `image`.
        func answer(_ image: CGImage?, keep: () -> Void) {
            guard let ending = end() else { return }
            ending.watchdog?.cancel()
            keep()
            releaseSlot()
            ending.resume?(.some(image))
        }

        /// Ends the making with `outcome`, unless it ended already: runs `keep`, stops a making
        /// whose call has returned and frees its slot, and ends the caller's wait.
        func abandon(with outcome: CGImage??, keep: () -> Void) {
            guard let ending = end() else { return }
            ending.watchdog?.cancel()
            keep()
            if let stop = ending.stop {
                stop()
                releaseSlot()
            }
            ending.resume?(outcome)
        }

        /// Marks the making ended, once, and hands back what ending it needs: the caller's
        /// resume, the give-up wait, and Quick Look's stop if its call has returned.
        private func end() -> (
            resume: (@Sendable (CGImage??) -> Void)?, watchdog: Task<Void, Never>?,
            stop: (@Sendable () -> Void)?
        )? {
            lock.withLock {
                guard !ended else { return nil }
                ended = true
                defer {
                    resume = nil
                    watchdog = nil
                }
                return (resume, watchdog, hasStarted ? stop : nil)
            }
        }

        private func releaseSlot() {
            let frees = lock.withLock {
                defer { slotFreed = true }
                return !slotFreed
            }
            if frees { freeSlot() }
        }
    }
}
