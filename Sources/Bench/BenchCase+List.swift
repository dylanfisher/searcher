import Base
import Browser
import Foundation

extension BenchCase {
    /// The lister alone, without the service around it: time to the first batch and to the full
    /// listing on W1, W2 and W5 (`/`), then the sort key and the sort on W2's entries. Reported
    /// only: B2 and B5 are measured through `ListingService` by `openFolder`, and B8 is the whole
    /// column change, not its parts. A `--path` folder replaces each workload.
    static let list: [BenchCase] = {
        var cases: [BenchCase] = []
        for (label, path) in [("W1", w1Path), ("W2", w2Path), ("W5", w5Path)] {
            cases.append(
                BenchCase(name: "list \(label): first batch", budget: nil, unit: .milliseconds) {
                    try firstBatch($0 ?? path)
                })
            cases.append(
                BenchCase(name: "list \(label): full", budget: nil, unit: .milliseconds) {
                    try full($0 ?? path)
                })
        }
        cases.append(
            BenchCase(name: "sort W2: key build", budget: nil, unit: .milliseconds) {
                let names = try entries($0 ?? w2Path).map(\.name)
                return time { _ = NameSortKey.keys(for: names) }
            })
        cases.append(
            BenchCase(
                name: "sort W2: listing build (keys, kinds, name order)", budget: nil,
                unit: .milliseconds
            ) {
                let entries = try entries($0 ?? w2Path)
                return time { _ = Listing(entries) }
            })
        cases.append(
            BenchCase(name: "sort W2: by size", budget: nil, unit: .milliseconds) {
                var listing = Listing(try entries($0 ?? w2Path))
                return time { listing.sort(by: .size, ascending: false) }
            })
        return cases
    }()

    /// `/`: every entry counts, hidden or not, because the lister has no hidden-file filter.
    private static let w5Path = "/"
    private static let w1Path = Fixture(.w1).path.path
    private static let w2Path = Fixture(.w2).path.path

    private static func firstBatch(_ path: String) throws -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        var elapsed: Duration?
        try DirectoryLister().list(path) { _ in elapsed = elapsed ?? clock.now - start }
        // An empty folder sends no batch, which would time nothing.
        guard let elapsed else { throw EmptyFolder(path: path) }
        return milliseconds(elapsed)
    }

    private static func full(_ path: String) throws -> Double {
        try time { try DirectoryLister().list(path) { _ in } }
    }

    private static func entries(_ path: String) throws -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        try DirectoryLister().list(path) { entries += $0 }
        return entries
    }

    private static func time(_ body: () throws -> Void) rethrows -> Double {
        milliseconds(try ContinuousClock().measure(body))
    }

    struct EmptyFolder: Error, CustomStringConvertible {
        let path: String
        var description: String { "\(path) is empty, so there is no first batch to time" }
    }
}
