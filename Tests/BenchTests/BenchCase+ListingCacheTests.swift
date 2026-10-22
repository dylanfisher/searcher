import Foundation
import TestSupport
import Testing

@testable import Bench

@Test func listingCacheCaseCoversB4() {
    #expect(BenchCase.listingCache.map(\.budget?.id) == ["B4"])
    #expect(BenchCase.registered.contains { $0.name == "cache hit → sorted Listing, 3.2k entries" })
}

@Test func listingCacheCaseRunsOnGeneratedEntriesAndOnAFolder() async throws {
    let folder = try TemporaryFolder("ListingCacheBenchTests")
    for name in ["a", "b", "c"] {
        try Data([1]).write(to: folder.url.appending(path: name))
    }
    for benchCase in BenchCase.listingCache {
        #expect(try await benchCase.run(nil) > 0)
        #expect(try await benchCase.run(folder.url.path) > 0)
    }
}
