import AppKit
import Browser

extension NSImage {
    /// A thumbnail `ThumbnailService` made, at its size in points. It wraps the pixels Quick Look
    /// drew, so drawing it decodes nothing.
    convenience init(thumbnail: CGImage) {
        let scale = ThumbnailService.scale
        self.init(
            cgImage: thumbnail,
            size: NSSize(
                width: Double(thumbnail.width) / scale, height: Double(thumbnail.height) / scale))
    }
}
