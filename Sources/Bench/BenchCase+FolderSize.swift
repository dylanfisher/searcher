import Base
import Browser
import Foundation

extension BenchCase {
    /// A folder size through `FolderSizeService`, timed from the request to the size reaching the
    /// main actor: the recursive part of B5, on W3's ~60k files in ~8k folders. Each run uses a
    /// new cache, so every run walks. A `--path` folder replaces W3.
    ///
    /// Then a batch of sizes for every folder in W2 (1,000 of its 100k entries) applied to its
    /// listing sorted by size, with one row selected, timed to the rows re-sorted and the
    /// selection resolved: the work `Pane` does off the main actor for each batch, the model part
    /// of B8. A `--path` folder replaces W2.
    static let folderSize: [BenchCase] = [
        BenchCase(name: "walk W3: folder size", budget: budget("B5.W3"), unit: .milliseconds) {
            try await timeWalk($0 ?? w3Path)
        },
        BenchCase(name: "W2: size updates re-sorted", budget: budget("B8"), unit: .milliseconds) {
            try timeSizeBatch($0 ?? w2Path)
        },
    ]

    private static let w3Path = Fixture(.w3).path.path
    private static let w2Path = Fixture(.w2).path.path

    private static func timeSizeBatch(_ path: String) throws -> Double {
        var entries: [DirectoryEntry] = []
        try DirectoryLister().list(path) { entries += $0 }
        guard !entries.isEmpty else { throw EmptyFolder(path: path) }
        var listing = Listing(entries, column: .size, ascending: false)
        let middle = ExactName(listing[listing.count / 2].name)
        let selection = Selection([middle], cursor: middle).resolved(
            in: listing, after: .sameEntries)
        // Sizes that differ from folder to folder, so the folders spread through the rows.
        var sizes: [ExactName: Listing.FolderSizeUpdate] = [:]
        for (index, entry) in entries.enumerated() where entry.type == .directory {
            sizes[ExactName(entry.name)] = Listing.FolderSizeUpdate(
                modified: entry.modified,
                value: .size(bytes: Int64(index) * 1_000, isPartial: false))
        }
        let start = ContinuousClock.now
        listing.applyFolderSizes(sizes)
        let resolved = selection.resolved(in: listing, after: .sameEntries)
        let elapsed = milliseconds(.now - start)
        guard resolved.cursorRow(in: listing) != nil else {
            preconditionFailure("the selection lost \(middle.name) in the re-sorted rows")
        }
        return elapsed
    }

    private static func timeWalk(_ path: String) async throws -> Double {
        let service = FolderSizeService(
            cache: FolderSizeCache(store: nil), log: { print("folder size: \($0)") })
        let start = ContinuousClock.now
        return try await withCheckedThrowingContinuation { continuation in
            service.requestSize(of: path, modified: Date(), for: PaneID()) { result in
                let elapsed = milliseconds(.now - start)
                continuation.resume(with: result.map { _ in elapsed })
            }
        }
    }
}
