import Base
import Browser
import Foundation

extension BenchCase {
    /// Typing a filter query on a loaded W2 pane with one row selected: the model part of B7.
    /// The query is the first five characters of the middle row's name, and the case for length
    /// n times the key that makes it n characters long, from setting the filter to the pane
    /// holding the filtered rows with the selection settled, which it does off the main actor.
    /// Each run lists the folder again in a new pane, with settings of its own in a `TempRoot`
    /// suite, and types the shorter queries untimed first. A `--path` folder replaces W2.
    static let filter: [BenchCase] = (1...filterQueryLength).map { length in
        BenchCase(
            name: "W2: filter key \(length) of \(filterQueryLength)", budget: budget("B7"),
            unit: .milliseconds
        ) { try await timeFilter(length, in: $0 ?? Fixture(.w2).path.path) }
    }

    private static let filterQueryLength = 5

    private static func timeFilter(_ length: Int, in path: String) async throws -> Double {
        let root = try TempRoot(prefix: "searcher-bench-filter")
        defer {
            do {
                try root.remove()
            } catch {
                printError("removing \(root.folder.path): \(error)")
            }
        }
        return try await timeFilter(length, in: path, suiteName: root.suiteName)
    }

    @MainActor
    private static func timeFilter(_ length: Int, in path: String, suiteName: String)
        async throws -> Double
    {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ViewBenchFailed(description: "UserDefaults refused the suite \(suiteName)")
        }
        let pane = Pane(
            location: Location(path: path), service: ListingService(),
            systemActions: NoSystemActions(), settings: Settings(defaults: defaults))
        await waitUntil(pane) {
            switch $0.state {
            case .loaded, .offline, .denied, .failed, .notConnected, .serverListed: true
            case .loading, .partial, .cachedRefreshing, .slow: false
            }
        }
        guard case .loaded(let listing) = pane.state, listing.count > 0 else {
            throw ViewBenchFailed(description: "\(path) didn't list any rows: \(pane.state)")
        }
        let middle = listing[listing.count / 2].name
        let query = String(middle.prefix(filterQueryLength))
        let before = String(query.prefix(length - 1))
        let typed = String(query.prefix(length))
        guard NameFilter(typed) != NameFilter(before) else {
            throw ViewBenchFailed(
                description: "typing \"\(typed)\" after \"\(before)\" changes no filter")
        }
        pane.select(Selection([ExactName(middle)], cursor: ExactName(middle)))
        if !before.isEmpty {
            pane.setFilter(before)
            await waitUntil(pane) { filtered($0, by: before) }
        }

        let start = ContinuousClock.now
        pane.setFilter(typed)
        await waitUntil(pane) { filtered($0, by: typed) }
        return milliseconds(.now - start)
    }

    /// Whether `pane` shows its rows filtered by `text`, with the selection settled.
    @MainActor
    private static func filtered(_ pane: Pane, by text: String) -> Bool {
        pane.state.listing?.filter == NameFilter(text) && pane.selection.isSettled
    }
}
