import Base
import Browser
import Foundation

extension BenchCase {
    /// A revisit of a folder on a share whose listing the cache holds in memory: from the lookup
    /// to a `Listing` sorted by name, with its sort keys and folded names rebuilt from the cached
    /// entries. The model part of B4. The entries are 3.2k generated names, about the largest
    /// folder in W4; a `--path` folder's entries replace them. The volume is made up, so nothing
    /// is read from a share.
    static let listingCache: [BenchCase] = [
        BenchCase(
            name: "cache hit → sorted Listing, 3.2k entries", budget: budget("B4"),
            unit: .milliseconds
        ) { try await timeCacheHit(entries: $0.map(listedEntries) ?? cachedEntries) }
    ]

    private static let cachedVolume = VolumeIdentity(
        device: "//bench@nas.invalid/Music", mountPoint: "/bench/Music", kind: .network)
    private static let cachedPath = "/bench/Music/Artist/Album"

    /// 3,200 file names with track numbers, words and extensions, from a fixed seed.
    private static let cachedEntries: [DirectoryEntry] = {
        var generator = SeededGenerator(seed: 42)
        let words = ["Intro", "Song", "Live", "Remix", "Ünïcødé", "日本語", "Demo", "Outro"]
        let extensions = ["flac", "m4a", "mp3", "jpg", "cue", "log"]
        return (0..<3_200).map { index in
            DirectoryEntry(
                name: "\(index % 30 + 1) \(generator.element(of: words)) \(index)."
                    + generator.element(of: extensions),
                type: .regular, size: Int64(generator.int(in: 0...80_000_000)),
                modified: Date(timeIntervalSince1970: Double(generator.int(in: 0...1_700_000_000))),
                isHidden: false, isDataless: false)
        }
    }()

    private static func listedEntries(_ path: String) throws -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        try DirectoryLister().list(path) { entries += $0 }
        return entries
    }

    private static func timeCacheHit(entries: [DirectoryEntry]) async throws -> Double {
        let cache = ListingCache(store: nil)
        await cache.insert(
            ListingCache.Folder(entries: entries, listedAt: Date()), at: cachedPath,
            on: cachedVolume)
        let start = ContinuousClock.now
        guard let folder = await cache.folder(at: cachedPath, on: cachedVolume) else {
            throw CacheMissed(path: cachedPath)
        }
        let listing = Listing(folder.entries)
        let elapsed = milliseconds(.now - start)
        guard listing.count == entries.count else {
            throw CacheMissed(path: cachedPath)
        }
        return elapsed
    }

    struct CacheMissed: Error, CustomStringConvertible {
        let path: String
        var description: String { "the cache didn't return all of \(path)'s entries" }
    }
}
