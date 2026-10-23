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

    /// The folder that holds this one, or nil for `/`.
    public var parent: Location? {
        let components = pathComponents(path)
        guard !components.isEmpty else { return nil }
        return Location(path: "/" + components.dropLast().joined(separator: "/"))
    }

    /// Every folder from `/` down to this one, this one last.
    public var ancestors: [Location] {
        var path = ""
        return [Location(path: "/")]
            + pathComponents(self.path).map { component in
                path += "/" + component
                return Location(path: path)
            }
    }

    /// The folder named `name` inside this one. Builds a path only; it doesn't check that the
    /// folder exists.
    ///
    /// - Precondition: `name` is one path component: not empty, and without a `/`.
    public func child(named name: String) -> Location {
        precondition(!name.isEmpty && !name.contains("/"), "\"\(name)\" isn't one path component")
        return Location(path: (path.hasSuffix("/") ? path : path + "/") + name)
    }
}
