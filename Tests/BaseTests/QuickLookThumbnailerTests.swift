import CoreGraphics
import Foundation
import TestSupport
import Testing

@testable import Base

/// The image `QuickLookThumbnailer` makes of the item at `path`, at 18 points and scale 2, as a
/// row asks for it; nil when it makes none.
private func rowImage(_ path: String) async -> CGImage? {
    nonisolated(unsafe) var image: CGImage?
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        BlockingCallThread.start {
            _ = QuickLookThumbnailer().makeThumbnail(at: path, side: 18, scale: 2, framed: true) {
                image = $0
                continuation.resume()
            }
        }
    }
    return image
}

/// The RGBA bytes of `image`, drawn into a bitmap of its own size.
private func pixels(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    try #require(drawn)
    return bytes
}

/// A folder's row shows the icon Finder draws for that folder, which Quick Look makes: a folder
/// with items in it shows a sheet of paper between its flaps where an empty one shows none, and a
/// tagged one takes its tag's color. The type's icon is the same for all three
/// (docs/decisions/0129-row-icons-as-finder.md).
@Test func aFolderGetsTheIconFinderDrawsForItsContentsAndTags() async throws {
    let folder = try TemporaryFolder("QuickLookThumbnailerTests")
    let empty = folder.url.appending(path: "empty").path
    let full = folder.url.appending(path: "full").path
    let tagged = folder.url.appending(path: "tagged").path
    for path in [empty, full, tagged] {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
    }
    try Data("a".utf8).write(to: URL(fileURLWithPath: full + "/a.txt"))
    try Data("a".utf8).write(to: URL(fileURLWithPath: tagged + "/a.txt"))
    try FinderTags.set(entries: ["Gray\n1"], at: tagged)

    let emptyIcon = try #require(await rowImage(empty))
    let fullIcon = try #require(await rowImage(full))
    let taggedIcon = try #require(await rowImage(tagged))

    for icon in [emptyIcon, fullIcon, taggedIcon] {
        #expect(icon.width == 36 && icon.height == 36)
    }
    #expect(try pixels(emptyIcon) != pixels(fullIcon))
    #expect(try pixels(fullIcon) != pixels(taggedIcon))
}
