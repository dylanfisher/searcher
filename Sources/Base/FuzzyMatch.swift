/// How well a fuzzy query matched one candidate, and where.
public struct FuzzyMatch: Sendable, Equatable {
    /// Higher is better. Only scores for the same query compare.
    public let score: Int
    /// The matched characters of the candidate's text, in order, with adjacent ones joined into
    /// one range. A letter matched inside a character that folds to several, as "f" in "ﬁ",
    /// covers the whole character. Empty for an empty query.
    public let ranges: [Range<String.Index>]

    public init(score: Int, ranges: [Range<String.Index>]) {
        self.score = score
        self.ranges = ranges
    }
}
