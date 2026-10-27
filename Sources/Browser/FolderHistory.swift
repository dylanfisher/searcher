import Foundation

/// The folders the user has visited, each with how many times and when last, for the palette to
/// rank them by frecency: the visit count weighted by how long ago the last visit was, as zoxide
/// weights it. `WorkspaceStore` keeps it in one file beside the session. At most `mostFolders`
/// are kept; a visit past that drops the least frecent. See
/// docs/decisions/0085-palette-ranking.md.
public struct FolderHistory: Codable, Equatable, Sendable {
    /// How many folders are kept.
    public static let mostFolders = 1_000

    /// One folder's visits.
    public struct Visits: Equatable, Sendable {
        public let count: Int
        public let last: Date
    }

    /// The visits of each folder, by path.
    public private(set) var folders: [String: Visits] = [:]

    public init() {}

    /// Stored as a list of folders sorted by path, so the same history always writes the same
    /// bytes and a path can't be listed twice unseen.
    private enum CodingKeys: String, CodingKey {
        case folders
    }

    private struct StoredFolder: Codable {
        let path: String
        let count: Int
        let last: Date
    }

    /// Throws for a file that breaks the history's rules, which the store then discards: more
    /// than `mostFolders` folders, a path that isn't absolute, listed twice or out of order, or
    /// a count under 1.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try container.decode([StoredFolder].self, forKey: .folders)
        func broken(_ reason: String) -> DecodingError {
            .dataCorruptedError(forKey: .folders, in: container, debugDescription: reason)
        }
        guard stored.count <= Self.mostFolders else {
            throw broken("it lists \(stored.count) folders, more than \(Self.mostFolders)")
        }
        var previous: String?
        for folder in stored {
            guard folder.path.hasPrefix("/") else {
                throw broken("\(folder.path) isn't an absolute path")
            }
            guard folder.count >= 1 else {
                throw broken("\(folder.path) has a visit count of \(folder.count)")
            }
            if let previous, folder.path <= previous {
                throw broken("\(folder.path) is listed twice or out of order")
            }
            previous = folder.path
            folders[folder.path] = Visits(count: folder.count, last: folder.last)
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(
            folders.sorted { $0.key < $1.key }.map {
                StoredFolder(path: $0.key, count: $0.value.count, last: $0.value.last)
            }, forKey: .folders)
    }

    /// Counts a visit to the folder at `path` at `date`. It takes a path, not a `Location`, so a
    /// server can't enter the history (0114-server-location.md).
    public mutating func visit(_ path: String, at date: Date) {
        let count = (folders[path]?.count ?? 0) + 1
        folders[path] = Visits(count: count, last: date)
        guard folders.count > Self.mostFolders else { return }
        let others = folders.filter { $0.key != path }
        guard
            let least = others.min(by: {
                Self.frecency(of: $0.value, at: date) < Self.frecency(of: $1.value, at: date)
            })
        else { return }
        folders[least.key] = nil
    }

    /// Drops the folder at `path`, as one found missing is, so the palette doesn't list it. A
    /// visit after counts it from 1. Returns whether the history had it.
    @discardableResult
    public mutating func forget(_ path: String) -> Bool {
        folders.removeValue(forKey: path) != nil
    }

    /// The visit count times 4 when the last visit was within the hour, 2 within the day, 1/2
    /// within the week and 1/4 before; 0 for a folder never visited. `path` is the folder's.
    public func frecency(of path: String, at now: Date) -> Double {
        folders[path].map { Self.frecency(of: $0, at: now) } ?? 0
    }

    /// Every folder kept, the most frecent first; equal ones by the later last visit, then by
    /// path.
    public func recent(at now: Date) -> [Location] {
        folders.map {
            (path: $0.key, visits: $0.value, frecency: Self.frecency(of: $0.value, at: now))
        }
        .sorted {
            if $0.frecency != $1.frecency { return $0.frecency > $1.frecency }
            if $0.visits.last != $1.visits.last { return $0.visits.last > $1.visits.last }
            return $0.path < $1.path
        }
        .map { Location(path: $0.path) }
    }

    private static func frecency(of visits: Visits, at now: Date) -> Double {
        let age = now.timeIntervalSince(visits.last)
        let weight =
            switch age {
            case ..<3_600: 4.0
            case ..<86_400: 2.0
            case ..<604_800: 0.5
            default: 0.25
            }
        return Double(visits.count) * weight
    }
}
