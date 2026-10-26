import CoreGraphics

/// Makes one file's thumbnail, as Finder shows it in place of the file's icon. Callers start it on
/// a `BlockingCallThread`: what an implementation does on the calling thread before it hands the
/// work on is not documented, and a file on a stalled disk can block it.
public protocol ThumbnailMaking: Sendable {
    /// Starts making the thumbnail of the file at `path`, at most `side` points square at `scale`
    /// pixels per point, and calls `done` once, on any thread, with the image, or with nil when
    /// the file has none or it can't be made. `framed` draws it as Finder's rows show it in
    /// place of an icon, a photo in a rounded frame with a shadow on a square canvas; unframed,
    /// it is the file's own image at its aspect, as Finder's column preview shows it. Returns a
    /// call that stops the making; `done` may still be called after it, or never.
    func makeThumbnail(
        at path: String, side: Double, scale: Double, framed: Bool,
        done: @escaping @Sendable (CGImage?) -> Void
    ) -> @Sendable () -> Void
}
