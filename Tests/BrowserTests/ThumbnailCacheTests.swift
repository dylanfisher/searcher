import Foundation
import TestSupport
import Testing

@testable import Browser

@Test func theCacheDropsTheLeastRecentlyUsedPastItsBytes() {
    let image = testThumbnail(pixels: 32)
    let cost = ThumbnailCache.entryBytes + image.bytesPerRow * image.height
    let cache = ThumbnailCache(mostBytes: 2 * cost)
    func key(_ name: String) -> ThumbnailCache.Key {
        ThumbnailCache.Key(path: "/p/\(name)", modified: testDate, size: 1, pixels: 32)
    }
    cache.store(image, for: key("a"))
    cache.store(image, for: key("b"))
    // "a" is used, so "b" is the least recently used.
    #expect(cache.value(for: key("a")) != nil)

    cache.store(image, for: key("c"))

    #expect(cache.value(for: key("b")) == nil)
    #expect(cache.value(for: key("a")) != nil)
    #expect(cache.value(for: key("c")) != nil)
    #expect(cache.keptBytes == 2 * cost)
}
