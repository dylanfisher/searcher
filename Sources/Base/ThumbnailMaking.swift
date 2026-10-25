import CoreGraphics

/// Makes one file's thumbnail, as Finder shows it in place of the file's icon. Callers start it on
/// a `BlockingCallThread`: what an implementation does on the calling thread before it hands the
/// work on is not documented, and a file on a stalled disk can block it.
public protocol ThumbnailMaking: Sendable {
    /// Starts making the thumbnail of the file at `path`, at most `side` points square at `scale`
    /// pixels per point, and calls `done` once, on any thread, with the image, or with nil when
    /// the file has none or it can't be made. Returns a call that stops the making; `done` may
    /// still be called after it, or never.
    func makeThumbnail(
        at path: String, side: Double, scale: Double,
        done: @escaping @Sendable (CGImage?) -> Void
    ) -> @Sendable () -> Void
}
