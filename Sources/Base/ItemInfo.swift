import Foundation

/// What Finder's preview shows of a file or package that its folder's listing doesn't have:
/// when it was created, when it was last opened and its tags.
public struct ItemInfo: Equatable, Sendable {
    /// Nil when the volume keeps no creation date, as some shares don't.
    public let created: Date?
    /// Spotlight's `kMDItemLastUsedDate`, the date Finder shows as Last opened. Nil when
    /// Spotlight has none, as for a file it hasn't indexed.
    public let lastOpened: Date?
    /// The Finder tags' names, in the order Finder lists them.
    public let tags: [String]

    public init(created: Date?, lastOpened: Date?, tags: [String]) {
        self.created = created
        self.lastOpened = lastOpened
        self.tags = tags
    }
}
