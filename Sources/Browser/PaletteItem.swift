import Base
import Foundation
import UniformTypeIdentifiers

/// One thing the palette can list and run: a command, a saved workspace, a folder, or, in Go to
/// Item, an entry the focused pane shows.
public struct PaletteItem: Sendable {
    /// What the item is, which no two items listed together share.
    public enum ID: Hashable, Sendable {
        case workspace(UUID)
        case folder(path: String)
        case command(CommandID)
        /// A row of the pane, or of its focused column, or, `isInSelectedFolder`, of the
        /// folder selected there.
        case entry(name: String, isInSelectedFolder: Bool)
    }

    /// The kinds in the order an empty query lists them, and equal scores rank them.
    public enum Kind: Int, Comparable, Sendable {
        case workspace
        case folder
        case command
        case entry

        public static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    public let id: ID
    /// What the query is matched against and the list shows, with the matched letters marked.
    public let title: String
    /// Shown beside the title, and not matched.
    public let detail: String?
    /// The chord that runs a command item; nil for other items and commands without one.
    public let chord: KeyChord?
    /// For a folder, `FolderHistory.frecency` when the item was made; 0 for other items.
    public let frecency: Double
    /// For an entry, the type whose icon its row shows; nil for other items, whose rows show
    /// their kind's.
    public let iconType: UTType?
    /// What choosing the item does.
    public let action: @MainActor @Sendable () -> Void
    /// The UTF-8 offset in `title` where matching starts. The query is matched from the same
    /// offset, so the title and the query must agree up to it: a typed path's folders are
    /// matched by the name typed after the last `/`.
    let matchOffset: Int
    /// `title` from `matchOffset`, prepared for matching.
    let candidate: FuzzyMatcher.Candidate

    public var kind: Kind {
        switch id {
        case .workspace: .workspace
        case .folder: .folder
        case .command: .command
        case .entry: .entry
        }
    }

    /// Prepares the title for matching, so make items off the main actor when there are many.
    ///
    /// - Precondition: `matchOffset` is a character boundary in `title`'s UTF-8.
    public init(
        id: ID, title: String, detail: String? = nil, chord: KeyChord? = nil,
        frecency: Double = 0, iconType: UTType? = nil, matchOffset: Int = 0,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        let start = title.utf8.index(title.startIndex, offsetBy: matchOffset)
        precondition(
            String.Index(start, within: title) != nil,
            "offset \(matchOffset) splits a character of \"\(title)\"")
        self.id = id
        self.title = title
        self.detail = detail
        self.chord = chord
        self.frecency = frecency
        self.iconType = iconType
        self.matchOffset = matchOffset
        self.action = action
        candidate = FuzzyMatcher.Candidate(String(title[start...]))
    }
}
