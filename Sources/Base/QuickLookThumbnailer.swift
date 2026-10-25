import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Asks Quick Look for a file's thumbnail. Quick Look makes it in its own process and keeps it in
/// the system's thumbnail cache, which Finder fills too, so a file Finder has shown comes back in
/// about 1 ms; one made fresh took 17–28 ms for a local JPEG
/// (docs/decisions/0102-thumbnails.md). It is drawn as Finder draws thumbnails in place of icons
/// (`iconMode`): a photo in a rounded frame, a document as a page.
public struct QuickLookThumbnailer: ThumbnailMaking {
    public init() {}

    public func makeThumbnail(
        at path: String, side: Double, scale: Double,
        done: @escaping @Sendable (CGImage?) -> Void
    ) {
        BlockingCallThread.requireCurrent()
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: path, isDirectory: false),
            size: CGSize(width: side, height: side), scale: scale,
            representationTypes: .thumbnail)
        request.iconMode = true
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            representation, _ in
            // The error says only that there is no thumbnail, as for a type Quick Look has no
            // generator for; the row keeps its type icon.
            done(representation?.cgImage)
        }
    }
}
