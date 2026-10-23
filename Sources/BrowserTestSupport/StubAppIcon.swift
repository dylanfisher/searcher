import CoreGraphics

/// A one-pixel image for an app's icon, a new one each call, so a test can tell icons apart by
/// identity.
public func stubAppIcon() -> CGImage {
    guard
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
        let image = context.makeImage()
    else {
        preconditionFailure("couldn't make a one-pixel image")
    }
    return image
}
