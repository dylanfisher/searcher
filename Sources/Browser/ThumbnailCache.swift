import Base
import CoreGraphics
import Foundation

/// Thumbnails made, by file version and size, at most `mostBytes` of them, the least recently
/// used dropped first. A file with no thumbnail is kept too, as nil, so a row scrolled back into
/// view doesn't ask again. Safe to use from any thread.
final class ThumbnailCache: @unchecked Sendable {
    /// One version of a file at one size, framed as a row's or not as the preview's. A file saved
    /// again has a new modification date or size, so its old thumbnail is never shown for it.
    struct Key: Hashable {
        let path: String
        let modified: Date
        let size: Int64?
        /// Drawn in Finder's icon frame, as rows show it (`ThumbnailMaking`).
        let framed: Bool
        /// The side asked for, in pixels.
        let pixels: Int

        /// The file version and framing, without the size asked for.
        var file: File { File(path: path, modified: modified, size: size, framed: framed) }
    }

    /// One version of a file, framed or not, at any size.
    struct File: Hashable {
        let path: String
        let modified: Date
        let size: Int64?
        let framed: Bool
    }

    /// What one kept entry costs beyond its pixels: the key, the node and the dictionary slot.
    static let entryBytes = 256

    private final class Node {
        let key: Key
        let image: CGImage?
        let bytes: Int
        var newer: Node?
        weak var older: Node?

        init(key: Key, image: CGImage?, bytes: Int) {
            self.key = key
            self.image = image
            self.bytes = bytes
        }
    }

    let mostBytes: Int
    // `lock` guards everything below.
    private let lock = NSLock()
    private var nodes: [Key: Node] = [:]
    /// The least recently used node; its `newer` chain runs to `newest`.
    private var oldest: Node?
    private var newest: Node?
    private var bytes = 0
    /// The sizes kept of each file version, in pixels, so a smaller one is found without a
    /// walk of every entry.
    private var pixelsByFile: [File: Set<Int>] = [:]

    init(mostBytes: Int) {
        self.mostBytes = mostBytes
    }

    /// The thumbnail kept for `key`: nil when none is kept, `.some(nil)` when the file has none.
    /// Marks it the most recently used.
    func value(for key: Key) -> CGImage?? {
        lock.withLock {
            guard let node = nodes[key] else { return nil }
            unlink(node)
            append(node)
            return .some(node.image)
        }
    }

    /// The largest thumbnail kept of `key`'s file version and framing smaller than `key` asks
    /// for, or nil when none is. Marks it the most recently used.
    func largestSmaller(than key: Key) -> CGImage? {
        lock.withLock {
            let smaller = (pixelsByFile[key.file] ?? []).filter { $0 < key.pixels }
            for pixels in smaller.sorted(by: >) {
                let file = key.file
                guard
                    let node = nodes[
                        Key(
                            path: file.path, modified: file.modified, size: file.size,
                            framed: file.framed, pixels: pixels)],
                    let image = node.image
                else { continue }
                unlink(node)
                append(node)
                return image
            }
            return nil
        }
    }

    /// Keeps `image`, or that the file has none, for `key`, dropping the least recently used
    /// entries past `mostBytes`.
    func store(_ image: CGImage?, for key: Key) {
        let cost = Self.entryBytes + (image.map { $0.bytesPerRow * $0.height } ?? 0)
        lock.withLock {
            if let old = nodes.removeValue(forKey: key) {
                unlink(old)
                bytes -= old.bytes
            }
            let node = Node(key: key, image: image, bytes: cost)
            nodes[key] = node
            pixelsByFile[key.file, default: []].insert(key.pixels)
            append(node)
            bytes += cost
            while bytes > mostBytes, let drop = oldest {
                unlink(drop)
                nodes[drop.key] = nil
                pixelsByFile[drop.key.file]?.remove(drop.key.pixels)
                if pixelsByFile[drop.key.file]?.isEmpty == true {
                    pixelsByFile[drop.key.file] = nil
                }
                bytes -= drop.bytes
            }
        }
    }

    /// The bytes kept, for tests.
    var keptBytes: Int { lock.withLock { bytes } }

    private func unlink(_ node: Node) {
        if let older = node.older { older.newer = node.newer } else { oldest = node.newer }
        if let newer = node.newer { newer.older = node.older } else { newest = node.older }
        node.newer = nil
        node.older = nil
    }

    private func append(_ node: Node) {
        node.older = newest
        newest?.newer = node
        newest = node
        if oldest == nil { oldest = node }
    }
}
