import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func filterCasesTypeOneToFiveCharactersOnW2UnderB7() {
    let cases = BenchCase.filter
    #expect(cases.count == 5)
    #expect(cases.allSatisfy { $0.name.hasPrefix("W2") && $0.budget?.id == "B7" })
    #expect(BenchCase.registered.contains { $0.name == cases[4].name })
}

@Test func filterCasesRunOnAFolder() async throws {
    let folder = try TemporaryFolder("FilterTests")
    for name in ["invoice-1.txt", "invoice-2.txt", "notes-3.md", "report-4.pdf", "track-5.flac"] {
        try Data([1]).write(to: folder.url.appending(path: name))
    }

    for benchCase in BenchCase.filter {
        #expect(try await benchCase.run(folder.url.path) > 0, "\(benchCase.name)")
    }
}
