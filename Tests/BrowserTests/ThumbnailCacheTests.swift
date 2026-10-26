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

/// The largest kept size of a file version below the one asked for, as the preview shows while
/// its own is made: not a larger one, not another version's, not a file's "none", not one
/// dropped.
@Test func theLargestSmallerThumbnailIsOfTheSameVersionAndStillKept() {
    let small = testThumbnail(pixels: 32)
    let medium = testThumbnail(pixels: 64)
    let cache = ThumbnailCache(mostBytes: 1 << 20)
    func key(_ pixels: Int, modified: Date = testDate) -> ThumbnailCache.Key {
        ThumbnailCache.Key(path: "/p/a.jpg", modified: modified, size: 1, pixels: pixels)
    }
    cache.store(small, for: key(32))
    cache.store(medium, for: key(64))
    cache.store(nil, for: key(128))
    cache.store(testThumbnail(pixels: 32), for: key(16, modified: testDate.addingTimeInterval(1)))

    #expect(cache.largestSmaller(than: key(1024)) === medium)
    #expect(cache.largestSmaller(than: key(64)) === small)
    #expect(cache.largestSmaller(than: key(32)) == nil)
    #expect(cache.largestSmaller(than: key(1024, modified: testDate.addingTimeInterval(2))) == nil)

    let other = testThumbnail(pixels: 32)
    let tight = ThumbnailCache(mostBytes: ThumbnailCache.entryBytes + small.bytesPerRow * 32)
    tight.store(small, for: key(32))
    tight.store(other, for: key(33))
    #expect(tight.value(for: key(32)) == nil)
    #expect(tight.largestSmaller(than: key(1024)) === other)
    #expect(tight.largestSmaller(than: key(33)) == nil)
}
