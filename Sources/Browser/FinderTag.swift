/// One of Finder's seven standard color tags, which the tag commands toggle
/// (docs/decisions/0121-tag-commands.md).
public struct FinderTag: Hashable, Sendable {
    /// The name the tag is written under. The system gives the standard names their colors.
    public let name: String
    /// Finder's label number for the color, 1 to 7: the index of its color in AppKit's
    /// `NSWorkspace.fileLabelColors`, and the number after the name in `_kMDItemUserTags`.
    public let label: Int

    /// The seven in the order Finder's menus show them.
    public static let all = [
        FinderTag(name: "Red", label: 6), FinderTag(name: "Orange", label: 7),
        FinderTag(name: "Yellow", label: 5), FinderTag(name: "Green", label: 2),
        FinderTag(name: "Blue", label: 4), FinderTag(name: "Purple", label: 3),
        FinderTag(name: "Gray", label: 1),
    ]

    /// How many of a selection's items have a tag, which its dot in the menu shows.
    public enum Coverage: Equatable, Sendable {
        case noItems, someItems, allItems
    }

    /// How many of the items whose tags are `tags` have this one; of no items, none.
    public func coverage(in tags: [[String]]) -> Coverage {
        let having = tags.filter { $0.contains(name) }.count
        if having == 0 { return .noItems }
        return having == tags.count ? .allItems : .someItems
    }
}
