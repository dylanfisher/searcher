import Base

extension BenchCase {
    /// Typing a palette query against 50k W3 paths: the matcher part of B11. The case for length
    /// n times the key that makes the query n letters long: every candidate scored against it and
    /// the best `fuzzyMatchLimit` kept with their ranges. Each key rescores every candidate, as
    /// the first key after opening the palette must. One more case times the last key of a
    /// 12-letter query, since a key's cost grows with the query's length. The paths come from
    /// W3's entry list, not the disk, and are prepared once, untimed, as the palette prepares them
    /// when it opens; the last case times that preparation. A `--path` folder doesn't apply.
    static let fuzzyMatch: [BenchCase] =
        (1...fuzzyMatchQuery.count).map { length in
            BenchCase(
                name: "W3 paths: palette key \(length) of \(fuzzyMatchQuery.count)",
                budget: budget("B11"), unit: .milliseconds
            ) { _ in timeFuzzyMatch(String(fuzzyMatchQuery.prefix(length))) }
        } + [
            BenchCase(
                name: "W3 paths: palette key \(fuzzyMatchLongQuery.count) of "
                    + "\(fuzzyMatchLongQuery.count)",
                budget: budget("B11"), unit: .milliseconds
            ) { _ in timeFuzzyMatch(fuzzyMatchLongQuery) },
            BenchCase(
                name: "W3 paths: prepare palette candidates", budget: budget("B11"),
                unit: .milliseconds
            ) { _ in timeCandidatePreparation() },
        ]

    /// Letters most W3 paths hold in order, so most candidates go through a full alignment.
    static let fuzzyMatchQuery = "srcmap"
    /// "node", "pkg", "src" and "map" shortened: in order in every `src` folder's map files.
    static let fuzzyMatchLongQuery = "nodpkgsrcmap"
    /// The rows a palette shows.
    static let fuzzyMatchLimit = 50
    /// The first 50,000 of W3's ~68k paths, relative to the fixture folder.
    static let fuzzyMatchPaths = Fixture(.w3).entries.prefix(50_000).map(\.path)
    static let fuzzyMatchCandidates = fuzzyMatchPaths.map(FuzzyMatcher.Candidate.init)

    private static func timeFuzzyMatch(_ query: String) -> Double {
        let candidates = fuzzyMatchCandidates
        let start = ContinuousClock.now
        let best = FuzzyMatcher(query).best(candidates, limit: fuzzyMatchLimit)
        let elapsed = milliseconds(.now - start)
        guard best.count == fuzzyMatchLimit else {
            preconditionFailure("\"\(query)\" kept \(best.count) of \(fuzzyMatchLimit) matches")
        }
        return elapsed
    }

    private static func timeCandidatePreparation() -> Double {
        let paths = fuzzyMatchPaths
        let start = ContinuousClock.now
        let candidates = paths.map(FuzzyMatcher.Candidate.init)
        let elapsed = milliseconds(.now - start)
        guard candidates.count == paths.count else {
            preconditionFailure("prepared \(candidates.count) of \(paths.count) paths")
        }
        return elapsed
    }
}
