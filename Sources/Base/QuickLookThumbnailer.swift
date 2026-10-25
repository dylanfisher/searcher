import CoreGraphics
import Darwin
import Foundation
import QuickLookThumbnailing

/// Asks Quick Look for a file's thumbnail. Quick Look makes it in its own process and keeps it in
/// the system's thumbnail cache, which Finder fills too, so a file Finder has shown comes back in
/// about 1 ms; one made fresh took 17–28 ms for a local JPEG
/// (docs/decisions/0102-thumbnails.md). It is drawn as Finder draws thumbnails in place of icons
/// (`iconMode`): a photo in a rounded frame, a document as a page.
public struct QuickLookThumbnailer: ThumbnailMaking {
    public init() {}

    /// A file whose contents aren't on this Mac gets none: Quick Look would read it, which
    /// downloads it (docs/decisions/0030-not-downloaded-badge.md). The flag is read with `lstat`,
    /// which doesn't download, just before asking; a file evicted between the two can still be
    /// read.
    public func makeThumbnail(
        at path: String, side: Double, scale: Double,
        done: @escaping @Sendable (CGImage?) -> Void
    ) -> @Sendable () -> Void {
        BlockingCallThread.requireCurrent()
        var info = stat()
        guard lstat(path, &info) == 0, info.st_flags & UInt32(SF_DATALESS) == 0 else {
            // Gone, or not downloaded: either way the row keeps its type icon.
            done(nil)
            return {}
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path, isDirectory: false),
            size: CGSize(width: side, height: side), scale: scale,
            representationTypes: .thumbnail)
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            representation, _ in
            // The error says only that there is no thumbnail, as for a type Quick Look has no
            // generator for, or that the request was cancelled; the row keeps its type icon.
            done(representation?.cgImage)
        }
        // The request is only handed back to the generator that made it.
        nonisolated(unsafe) let made = request
        return { QLThumbnailGenerator.shared.cancel(made) }
    }
}
