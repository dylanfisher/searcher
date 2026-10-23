import Foundation

/// Files `StubSystemActions` was asked to open in an app.
public struct OpenedWithApp: Equatable {
    public let urls: [URL]
    public let application: URL

    public init(urls: [URL], application: URL) {
        self.urls = urls
        self.application = application
    }
}
