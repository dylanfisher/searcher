import Base
import Foundation

/// The command palette's model: the query, the best `limit` items for it from every source, and
/// running the chosen one. Each query gathers every source's items again and ranks them off the
/// main actor; items a source hands over for an earlier query, and a ranking a later one
/// replaced, are dropped. See docs/decisions/0085-palette-ranking.md.
///
/// An item's score is its fuzzy match score plus `workspaceBonus` for a saved workspace and up to
/// `mostFrecencyBonus` for a folder the user visits often and lately (`frecencyBonus(_:)`).
/// Equal scores rank workspaces, then folders, then commands; then the folder with the larger
/// frecency bonus; then as `FuzzyMatcher.best` ranks them, the shorter text first; then the more
/// frecent folder. An empty query lists workspaces, then folders, then commands, each kind in
/// its source's order.
@MainActor
public final class Palette {
    /// The rows the palette shows.
    nonisolated public static let limit = 50
    /// Added to a saved workspace's score. More than `mostFrecencyBonus`, so at an equal match a
    /// workspace the user named ranks above any folder.
    nonisolated static let workspaceBonus = 5
    /// The most `frecencyBonus(_:)` adds.
    nonisolated static let mostFrecencyBonus = 4

    /// An item for the query, with its title's matched letters.
    public struct Result: Sendable {
        public let item: PaletteItem
        /// The matched letters of `item.title`.
        public let ranges: [Range<String.Index>]
        /// The match score with the item's bonuses; 0 plus the bonuses for an empty query.
        public let score: Int
    }

    public private(set) var query = ""
    /// The best items for `query`, best first, once ranked; until then the previous query's.
    public private(set) var results: [Result] = []
    /// Goes up with each query. Items handed over for an earlier one are dropped.
    public private(set) var generation = 0
    /// Runs on the main actor each time `results` changes.
    public var onChange: (@MainActor () -> Void)?

    private let sources: [any PaletteSource]
    private let limit: Int
    /// Each source's items for the query, in source order.
    private var gathered: [[PaletteItem]]
    /// Set while `setQuery` asks the sources, so the sync ones' items are ranked once.
    private var isGathering = false
    /// Counts rankings asked; only the latest one's results are kept.
    private var rankRequest = 0
    /// The ranking whose results `results` holds.
    private var rankedRequest = 0

    /// The latest ranking, cancelled when a later one replaces it.
    private(set) var ranking: Task<[Result], Never>?

    /// Whether a ranking is still running. Tests wait on it.
    var isRanking: Bool { rankedRequest != rankRequest }

    /// Sources are asked in order; an item a later source hands over again, such as a typed
    /// path's folder that was visited, is dropped.
    public init(sources: [any PaletteSource], limit: Int = Palette.limit) {
        precondition(limit > 0, "a palette of \(limit) rows")
        self.sources = sources
        self.limit = limit
        gathered = Array(repeating: [], count: sources.count)
    }

    /// Shows the items for `query`, once every sync source's items are ranked, and again each
    /// time a streaming source hands over more.
    public func setQuery(_ query: String) {
        self.query = query
        generation += 1
        let generation = generation
        gathered = Array(repeating: [], count: sources.count)
        isGathering = true
        for (index, source) in sources.enumerated() {
            source.gather(query) { [weak self] items in
                guard let self, self.generation == generation else { return }
                gathered[index] = items
                if !isGathering { rank() }
            }
        }
        isGathering = false
        rank()
    }

    /// Runs `result`'s item.
    public func run(_ result: Result) {
        result.item.action()
    }

    /// Stops the sources' work, as the palette closes.
    public func close() {
        for source in sources {
            source.cancel()
        }
    }

    private func rank() {
        rankRequest += 1
        let request = rankRequest
        let gathered = gathered
        let query = query
        let limit = limit
        self.ranking?.cancel()
        let ranking = Task.detached(priority: .userInitiated) {
            Self.rank(gathered, for: query, limit: limit)
        }
        self.ranking = ranking
        Task { [weak self] in
            let results = await ranking.value
            guard let self, request == rankRequest else { return }
            rankedRequest = request
            self.results = results
            onChange?()
        }
    }

    /// What a folder's frecency adds to its score: the whole part of its base-2 logarithm, from
    /// 0 below 2 to `mostFrecencyBonus` from 16. One visit within the hour (4) adds 2, ten (40)
    /// add 4.
    nonisolated static func frecencyBonus(_ frecency: Double) -> Int {
        guard frecency >= 1 else { return 0 }
        return min(mostFrecencyBonus, Int(log2(frecency)))
    }

    nonisolated private static func kindBonus(_ kind: PaletteItem.Kind) -> Int {
        kind == .workspace ? workspaceBonus : 0
    }

    /// The best `limit` of `gathered`'s items for `query`, without the items an earlier source
    /// handed over. Stops before the next bucket once `isCancelled`, returning nothing, since a
    /// later query's ranking replaces it.
    nonisolated static func rank(
        _ gathered: [[PaletteItem]], for query: String, limit: Int,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) -> [Result] {
        var seen: Set<PaletteItem.ID> = []
        var items: [PaletteItem] = []
        for batch in gathered {
            for item in batch where seen.insert(item.id).inserted {
                items.append(item)
            }
        }
        guard !query.allSatisfy(\.isWhitespace) else {
            return firstOfEachKind(items, limit: limit)
        }
        // Items of one bucket share their bonus and their kind, so `best` ranks them by match
        // alone; sorted most frecent first, its last tie-break, the earlier index, follows
        // frecency. The buckets' best are then merged by score.
        var buckets: [Bucket: [PaletteItem]] = [:]
        for item in items {
            let bucket = Bucket(
                matchOffset: item.matchOffset, kind: item.kind,
                frecencyBonus: frecencyBonus(item.frecency))
            buckets[bucket, default: []].append(item)
        }
        var ranked: [Ranked] = []
        for (bucket, unsorted) in buckets {
            if isCancelled() { return [] }
            let items =
                unsorted.allSatisfy({ $0.frecency == unsorted[0].frecency })
                ? unsorted
                : unsorted.enumerated().sorted {
                    $0.element.frecency != $1.element.frecency
                        ? $0.element.frecency > $1.element.frecency : $0.offset < $1.offset
                }.map(\.element)
            let matched = matchedQuery(query, from: bucket.matchOffset, of: items[0].title)
            let best = FuzzyMatcher(matched).best(items.map(\.candidate), limit: limit)
            for (place, found) in best.enumerated() {
                ranked.append(
                    Ranked(
                        item: items[found.index], match: found.match,
                        score: found.match.score + kindBonus(bucket.kind)
                            + bucket.frecencyBonus,
                        bucket: bucket, place: place))
            }
        }
        ranked.sort()
        return ranked.prefix(limit).map { ranked in
            Result(
                item: ranked.item,
                ranges: ranked.match.ranges.map {
                    titleRange($0, in: ranked.item)
                },
                score: ranked.score)
        }
    }

    /// The query an item whose matching starts at `offset` is matched with: the rest of `query`
    /// from there. Up to it, `query` and the item's title agree.
    nonisolated private static func matchedQuery(
        _ query: String, from offset: Int, of title: String
    )
        -> String
    {
        guard offset > 0 else { return query }
        precondition(
            query.utf8.starts(with: title.utf8.prefix(offset)),
            "\"\(title)\" is matched from \(offset), where it doesn't agree with \"\(query)\"")
        return String(decoding: query.utf8.dropFirst(offset), as: UTF8.self)
    }

    /// `range` of the item's candidate text, as a range of its title.
    nonisolated private static func titleRange(_ range: Range<String.Index>, in item: PaletteItem)
        -> Range<String.Index>
    {
        let text = item.candidate.text
        let title = item.title
        let lower = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
        let upper = text.utf8.distance(from: text.startIndex, to: range.upperBound)
        return title.utf8.index(
            title.startIndex, offsetBy: item.matchOffset + lower)..<title.utf8.index(
                title.startIndex, offsetBy: item.matchOffset + upper)
    }

    /// Up to `limit` of `items`: workspaces, then folders, then commands, each in source order.
    nonisolated private static func firstOfEachKind(_ items: [PaletteItem], limit: Int)
        -> [Result]
    {
        var results: [Result] = []
        for kind in [PaletteItem.Kind.workspace, .folder, .command] {
            for item in items where item.kind == kind {
                guard results.count < limit else { return results }
                results.append(
                    Result(
                        item: item, ranges: [],
                        score: kindBonus(kind) + frecencyBonus(item.frecency)))
            }
        }
        return results
    }

    /// Items `rank` scores together: the same kind, frecency bonus and match offset.
    private struct Bucket: Hashable {
        let matchOffset: Int
        let kind: PaletteItem.Kind
        let frecencyBonus: Int
    }

    /// A bucket's match, ordered best first.
    private struct Ranked: Comparable {
        let item: PaletteItem
        let match: FuzzyMatch
        let score: Int
        let bucket: Bucket
        /// Its place in its bucket's `best`.
        let place: Int

        static func < (a: Ranked, b: Ranked) -> Bool {
            if a.score != b.score { return a.score > b.score }
            if a.bucket.kind != b.bucket.kind { return a.bucket.kind < b.bucket.kind }
            if a.bucket.frecencyBonus != b.bucket.frecencyBonus {
                return a.bucket.frecencyBonus > b.bucket.frecencyBonus
            }
            if a.place != b.place { return a.place < b.place }
            return a.bucket.matchOffset < b.bucket.matchOffset
        }

        static func == (a: Ranked, b: Ranked) -> Bool { !(a < b) && !(b < a) }
    }
}
