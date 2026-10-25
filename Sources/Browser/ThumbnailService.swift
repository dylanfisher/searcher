import Base
import CoreGraphics
import Foundation

/// Makes the thumbnails that list rows, column rows and the column preview show in place of a
/// file's type icon, and keeps the latest in a `ThumbnailCache`. Each request is placed on its
/// volume by the mount table and started on a `BlockingCallThread`, at most
/// `ListingService.mostReads(on:)` at once on a volume, apart from the loads' and the info reads'
/// slots. A file on a network volume gets none: one costs 85 ms per audio file over SMB
/// (docs/decisions/0004-listing-view.md, docs/decisions/0038-slow-volumes.md,
/// docs/decisions/0102-thumbnails.md).
public final class ThumbnailService: Sendable {
    /// Pixels per point of every thumbnail made. Retina's; a 1x display draws it scaled down,
    /// which costs a 16-point row 3 KB more than its own scale would.
    public static let scale = 2.0
    /// The cache's limit: about 7,000 row thumbnails or 120 preview ones.
    public static let mostCachedBytes = 32 << 20

    private let maker: any ThumbnailMaking
    /// Reads the mount table on a request's thread, without asking any volume.
    private let mountedVolumes: @Sendable () -> [VolumeIdentity]
    private let cache: ThumbnailCache
    /// The requests making a thumbnail and waiting for a slot, per volume.
    let calls = InfoReads()

    public init(
        maker: any ThumbnailMaking = QuickLookThumbnailer(),
        mountedVolumes: @escaping @Sendable () -> [VolumeIdentity] = VolumeIdentity.mounted,
        mostCachedBytes: Int = ThumbnailService.mostCachedBytes
    ) {
        self.maker = maker
        self.mountedVolumes = mountedVolumes
        cache = ThumbnailCache(mostBytes: mostCachedBytes)
    }

    /// Whether `entry`, of `kind`, may show a thumbnail: a regular file whose contents are on
    /// this Mac, since making one reads them (docs/decisions/0030-not-downloaded-badge.md), and
    /// that isn't text, which keeps its type icon as Finder shows it. Folders, packages and links
    /// keep their icons.
    public static func shows(_ entry: DirectoryEntry, kind: EntryKind) -> Bool {
        entry.type == .regular && !entry.isDataless && !kind.isText
    }

    /// The thumbnail kept of `entry`, the file at `path`, at `side` points: nil when none is
    /// kept, `.some(nil)` when it was asked for and the file has none. Reads no file.
    public func cached(at path: String, entry: DirectoryEntry, side: Double) -> CGImage?? {
        cache.value(for: Self.key(path, entry, side))
    }

    /// The thumbnail of `entry`, the file at `path`, at `side` points, from the cache or made and
    /// kept there; nil when the file has none, or is on a network volume. Throws when the calling
    /// task is cancelled while the request waits for its volume's slot; a thumbnail already being
    /// made is still kept.
    public func thumbnail(at path: String, entry: DirectoryEntry, side: Double)
        async throws(CancellationError) -> CGImage?
    {
        let key = Self.key(path, entry, side)
        if let kept = cache.value(for: key) { return kept }
        let calls = calls
        let cache = cache
        let maker = maker
        let mountedVolumes = mountedVolumes
        let id = calls.makeID()
        // Nil when cancelled before it started; otherwise the thumbnail, nil if there is none.
        let outcome: CGImage?? = await withTaskCancellationHandler {
            await withCheckedContinuation {
                (continuation: CheckedContinuation<CGImage??, Never>) in
                BlockingCallThread.start {
                    let volume = ListingService.longestMount(holding: path, in: mountedVolumes())
                    if volume?.kind == .network {
                        cache.store(nil, for: key)
                        continuation.resume(returning: .some(nil))
                        return
                    }
                    calls.enter(
                        id, on: volume, cancelled: { continuation.resume(returning: .none) }
                    ) {
                        maker.makeThumbnail(at: path, side: side, scale: Self.scale) { image in
                            cache.store(image, for: key)
                            continuation.resume(returning: .some(image))
                            calls.finish(id, on: volume)
                        }
                    }
                }
            }
        } onCancel: {
            calls.cancel(id)
        }
        // A cancel that landed after the request finished, or on a network volume's, which never
        // entered, left the id behind as cancelled early; no cancel can land after this.
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
}
