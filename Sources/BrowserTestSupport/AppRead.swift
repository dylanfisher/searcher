import Foundation

/// An app `StubSystemActions` was asked to read, and whether it was asked on the main thread.
public struct AppRead: Sendable {
    public let url: URL
    public let onMainThread: Bool

    public init(url: URL, onMainThread: Bool) {
        self.url = url
        self.onMainThread = onMainThread
    }
}
