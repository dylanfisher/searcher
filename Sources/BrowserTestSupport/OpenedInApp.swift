import Foundation

/// A folder `StubSystemActions` was asked to open in an app.
public struct OpenedInApp: Equatable {
    public let folder: URL
    public let bundleID: String

    public init(folder: URL, bundleID: String) {
        self.folder = folder
        self.bundleID = bundleID
    }
}
