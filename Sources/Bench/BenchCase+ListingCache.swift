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
        ) { try await timeCacheHit(entries: $0.map(listedEntries) ?? cachedEntries) },
        BenchCase(
            name: "revisit → pane shows cached rows, 3.2k entries", budget: budget("B4"),
            unit: .milliseconds
        ) { try await timeCachedRows(entries: $0.map(listedEntries) ?? cachedEntries) },
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

    /// A pane opening a folder the cache holds in memory, through `ListingService`: from the
    /// pane asking for the folder to it holding the cached rows, sorted, with the selection
    /// resolved. The share's read is held until then, as a share that answers late holds it, and
    /// lets the full listing land before the next run.
    private static func timeCachedRows(entries: [DirectoryEntry]) async throws -> Double {
        let root = try TempRoot(prefix: "searcher-bench-cached")
        defer {
            do {
                try root.remove()
            } catch {
                printError("removing \(root.folder.path): \(error)")
            }
        }
        let cache = ListingCache(store: nil)
        await cache.insert(
            ListingCache.Folder(entries: entries, listedAt: Date()), at: cachedPath,
            on: cachedVolume)
        return try await timeCachedRows(
            entries: entries, cache: cache, suiteName: root.suiteName)
    }

    @MainActor
    private static func timeCachedRows(
        entries: [DirectoryEntry], cache: ListingCache, suiteName: String
    ) async throws -> Double {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ViewBenchFailed(description: "UserDefaults refused the suite \(suiteName)")
        }
        let lister = HeldLister(entries: entries)
        let service = ListingService(
            lister: lister, volumeOf: { _ in cachedVolume }, cache: cache)
        let start = ContinuousClock.now
        let pane = Pane(
            location: Location(path: cachedPath), service: service,
            systemActions: NoSystemActions(), settings: Settings(defaults: defaults))
        await waitUntil(pane) { pane in
            if case .cachedRefreshing = pane.state { true } else { false }
        }
        let elapsed = milliseconds(.now - start)
        guard pane.state.listing?.count == entries.count else {
            throw CacheMissed(path: cachedPath)
        }
        lister.release()
        await waitUntil(pane) { pane in
            if case .loaded = pane.state { true } else { false }
        }
        return elapsed
    }

    /// Holds each read until `release`, then returns `entries` in one batch.
    private final class HeldLister: Lister, @unchecked Sendable {
        private let entries: [DirectoryEntry]
        private let released = DispatchSemaphore(value: 0)

        init(entries: [DirectoryEntry]) {
            self.entries = entries
        }

        func list(_ path: String, onBatch: ([DirectoryEntry]) throws -> Void) throws {
            released.wait()
            try onBatch(entries)
        }

        func release() {
            released.signal()
        }
    }

    struct CacheMissed: Error, CustomStringConvertible {
        let path: String
        var description: String { "the cache didn't return all of \(path)'s entries" }
    }
}
