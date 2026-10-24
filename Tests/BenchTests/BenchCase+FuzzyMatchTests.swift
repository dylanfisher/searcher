import Base
import Testing

@testable import Bench

@Test func fuzzyMatchCasesTypeOneToSixLettersOnW3PathsUnderB11() {
    let cases = BenchCase.fuzzyMatch
    #expect(cases.count == 6)
    #expect(cases.allSatisfy { $0.name.hasPrefix("W3 paths") && $0.budget?.id == "B11" })
    #expect(BenchCase.registered.contains { $0.name == cases[5].name })
}

@Test func fuzzyMatchCandidatesAre50kW3PathsAndTheFullQueryKeepsATopFifty() {
    #expect(BenchCase.fuzzyMatchCandidates.count == 50_000)
    #expect(BenchCase.fuzzyMatchQuery.count == 6)
    let best = FuzzyMatcher(BenchCase.fuzzyMatchQuery).best(
        BenchCase.fuzzyMatchCandidates, limit: BenchCase.fuzzyMatchLimit)
    #expect(best.count == BenchCase.fuzzyMatchLimit)
}

@Test func fuzzyMatchCaseRuns() async throws {
    #expect(try await BenchCase.fuzzyMatch[5].run(nil) > 0)
}
