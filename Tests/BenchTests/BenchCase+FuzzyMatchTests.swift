import Base
import Testing

@testable import Bench

@Test func fuzzyMatchCasesCoverEachKeyALongQueryAndPreparationUnderB11() {
    let cases = BenchCase.fuzzyMatch
    #expect(
        cases.map(\.name)
            == (1...6).map { "W3 paths: palette key \($0) of 6" } + [
                "W3 paths: palette key 12 of 12", "W3 paths: prepare palette candidates",
            ])
    #expect(cases.allSatisfy { $0.budget?.id == "B11" })
    let registered = Set(BenchCase.registered.map(\.name))
    #expect(cases.allSatisfy { registered.contains($0.name) })
}

@Test(arguments: [BenchCase.fuzzyMatchQuery, BenchCase.fuzzyMatchLongQuery])
func fuzzyMatchQueriesKeepATopFiftyOf50kW3Paths(query: String) {
    #expect(BenchCase.fuzzyMatchCandidates.count == 50_000)
    let best = FuzzyMatcher(query).best(
        BenchCase.fuzzyMatchCandidates, limit: BenchCase.fuzzyMatchLimit)
    #expect(best.count == BenchCase.fuzzyMatchLimit)
}

@Test func fuzzyMatchQueriesAreSixAndTwelveLetters() {
    #expect(BenchCase.fuzzyMatchQuery.count == 6)
    #expect(BenchCase.fuzzyMatchLongQuery.count == 12)
}

@Test func fuzzyMatchCasesRun() async throws {
    for benchCase in BenchCase.fuzzyMatch.suffix(3) {
        #expect(try await benchCase.run(nil) > 0, "\(benchCase.name)")
    }
}
