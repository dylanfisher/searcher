import AppKit
import Testing
import UniformTypeIdentifiers

@testable import Interface

/// Makes a new image per call and counts the calls by type.
@MainActor
final class IconMaker {
    private(set) var calls: [UTType: Int] = [:]

    func icon(for type: UTType) -> NSImage {
        calls[type, default: 0] += 1
        return NSImage(size: NSSize(width: 16, height: 16))
    }
}

@MainActor @Test func makesOneIconPerType() {
    let maker = IconMaker()
    let cache = TypeIconCache(makeIcon: maker.icon(for:))

    let first = cache.icon(for: .mp3)
    let second = cache.icon(for: .mp3)
    let folder = cache.icon(for: .folder)

    #expect(first === second)
    #expect(first !== folder)
    #expect(maker.calls == [.mp3: 1, .folder: 1])
}
