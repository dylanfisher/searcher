import Base

/// A place shown in a pane: a directory, or a connected server whose shares are its folders.
public enum Location: Hashable, Sendable {
    case folder(path: String)
    case server(Server)

    public init(path: String) {
        self = .folder(path: path)
    }

    /// The folder's path, for users that touch the file system or are reached only from a
    /// folder pane.
    ///
    /// - Precondition: this is a folder. A server has no path to read or write.
    public var folderPath: String {
        guard case .folder(let path) = self else {
            preconditionFailure("a server has no folder path")
        }
        return path
    }

    /// The folder's path, or nil for a server, for users that must decide what a server does.
    public var path: String? {
        guard case .folder(let path) = self else { return nil }
        return path
    }

    /// Whether this is a folder. Every command and drop that is off at a server reads this.
    public var isFolder: Bool {
        path != nil
    }

    public var name: String {
        switch self {
        case .folder(let path): pathComponents(path).last.map(String.init) ?? "/"
        case .server(let server): server.name
        }
    }

    /// The folder that holds this one, or nil for `/` and for a server.
    public var parent: Location? {
        guard case .folder(let path) = self else { return nil }
        let components = pathComponents(path)
        guard !components.isEmpty else { return nil }
        return Location(path: "/" + components.dropLast().joined(separator: "/"))
    }

    /// Every folder from `/` down to this one, this one last. A server is its only ancestor.
    public var ancestors: [Location] {
        guard case .folder(let path) = self else { return [self] }
        var ancestorPath = ""
        return [Location(path: "/")]
            + pathComponents(path).map { component in
                ancestorPath += "/" + component
                return Location(path: ancestorPath)
            }
    }

    /// The folder named `name` inside this one. Builds a path only; it doesn't check that the
    /// folder exists. A server's rows go through `Pane.childLocation(of:)`, which asks the mount
    /// table whose share a row is (docs/decisions/0115-server-shares.md).
    ///
    /// - Precondition: this is a folder, and `name` is one path component: not empty, and
    ///   without a `/`.
    public func folderChild(named name: String) -> Location {
        precondition(!name.isEmpty && !name.contains("/"), "\"\(name)\" isn't one path component")
        return Location(path: (folderPath.hasSuffix("/") ? folderPath : folderPath + "/") + name)
    }
}
