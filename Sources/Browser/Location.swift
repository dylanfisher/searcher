import Base

/// A directory shown in a pane.
public struct Location: Equatable, Sendable {
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public var name: String {
        pathComponents(path).last.map(String.init) ?? "/"
    }
}
