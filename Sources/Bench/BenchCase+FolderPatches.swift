import Base
import Browser
import Foundation

extension BenchCase {
    /// A burst of new files, as unzipping or copying into W2 makes, reaching a loaded W2 pane
    /// with one row selected as one folder change: 500, 5,000, 20,000 and 50,000 entries, each
    /// timed from `Pane.apply`, the path the folder monitor's batches take, to the pane holding
    /// its next listing with the selection settled. A batch over `FolderChange.patchLimit` lists
    /// the folder again instead of patching, so those cases time a W2 relist, whose rows lack the
    /// entries, since nothing is written to disk; the 500 case patches. The entries are made once,
    /// untimed. Each run lists the folder in a new pane, with settings of its own in a `TempRoot`
    /// suite. Reported only; a `--path` folder replaces W2.
    /// See docs/decisions/0020-folder-monitor.md.
    static let folderPatches: [BenchCase] = [500, 5_000, 20_000, 50_000].map { count in
        BenchCase(
            name: "W2: folder change adding \(count) entries", budget: nil,
            unit: .milliseconds, runs: count > 5_000 ? 5 : BenchCase.runs
        ) { try await timeFolderPatches(count, in: $0 ?? Fixture(.w2).path.path) }
    }

    /// 50,000 new files with names spread through W2's name order, so the patches insert all
    /// over the listing rather than at one end.
    private static let addedEntries: [DirectoryEntry] = {
        var generator = SeededGenerator(seed: 8)
        let words = ["archive", "build", "export", "photo", "report", "scan", "track", "zeta"]
        let extensions = ["txt", "png", "jpg", "pdf", "json"]
        return (0..<50_000).map { index in
            DirectoryEntry(
                name: "\(generator.element(of: words))-added-\(index)-"
                    + "\(UInt32(truncatingIfNeeded: generator.next())).\(generator.element(of: extensions))",
                type: .regular, size: Int64(generator.int(in: 0...10_000_000)),
                modified: Date(timeIntervalSince1970: 1_767_225_600), isHidden: false,
                isDataless: false)
        }
    }()

    private static func timeFolderPatches(_ count: Int, in path: String) async throws -> Double {
        let root = try TempRoot(prefix: "searcher-bench-patches")
        defer {
            do {
                try root.remove()
            } catch {
                printError("removing \(root.folder.path): \(error)")
            }
        }
        let patches = addedEntries.prefix(count).map { FolderChange.Patch.update($0) }
        return try await timeFolderPatches(patches, in: path, suiteName: root.suiteName)
    }

    @MainActor
    private static func timeFolderPatches(
        _ patches: [FolderChange.Patch], in path: String, suiteName: String
    ) async throws -> Double {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ViewBenchFailed(description: "UserDefaults refused the suite \(suiteName)")
        }
        let pane = Pane(
            location: Location(path: path), service: ListingService(),
            systemActions: NoSystemActions(),
            settings: Settings(defaults: defaults, log: printError))
        await waitUntil(pane) {
            switch $0.state {
            case .loaded, .offline, .denied, .failed, .notConnected, .serverListed: true
            case .loading, .partial, .cachedRefreshing, .slow: false
            }
        }
        guard case .loaded(let listing) = pane.state, listing.count > 0 else {
            throw ViewBenchFailed(description: "\(path) didn't list any rows: \(pane.state)")
        }
        let middle = ExactName(listing[listing.count / 2].name)
        pane.select(Selection([middle], cursor: middle))
        let version = pane.stateVersion

        let start = ContinuousClock.now
        pane.apply(.patches(patches), at: pane.location)
        await waitUntil(pane) { pane in
            guard pane.stateVersion > version, case .loaded = pane.state else { return false }
            return pane.selection.isSettled
        }
        return milliseconds(.now - start)
    }
}
