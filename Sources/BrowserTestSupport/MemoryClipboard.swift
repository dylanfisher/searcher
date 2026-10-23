import Browser
import Foundation

/// A clipboard in memory, so no test writes a pasteboard. `otherAppWrites` stands for any write
/// Searcher didn't make.
@MainActor
public final class MemoryClipboard: FileClipboard {
    public private(set) var changeCount = 0
    private var urls: [URL] = []

    public init() {}

    public func write(_ urls: [URL]) {
        self.urls = urls
        changeCount += 1
    }

    public func fileURLs() -> [URL] { urls }

    public func otherAppWrites(_ urls: [URL] = []) {
        write(urls)
    }
}
