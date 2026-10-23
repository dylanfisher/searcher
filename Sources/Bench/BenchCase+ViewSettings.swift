import Base
import Browser
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension BenchCase {
    /// The view commands on a loaded pane with one row selected, each timed from running the
    /// command to the pane holding the re-sorted rows with the selection resolved, which it does
    /// off the main actor: the model part of B8. Showing and hiding hidden files and turning
    /// folders first on, on W2 (B8) and W5 (reported only), and the sort key for Size on W2 (B8).
    /// Each run lists the folder again in a new pane, with settings of its own in a `TempRoot`
    /// suite. A `--path` folder replaces each workload.
    static let viewSettings: [BenchCase] = {
        var cases: [BenchCase] = []
        for (label, path, budget) in [("W2", w2Path, budget("B8")), ("W5", w5Path, nil)] {
            cases.append(
                BenchCase(name: "\(label): show hidden files", budget: budget, unit: .milliseconds)
                { try await time(.showHidden, in: $0 ?? path) })
            cases.append(
                BenchCase(name: "\(label): hide hidden files", budget: budget, unit: .milliseconds)
                { try await time(.hideHidden, in: $0 ?? path) })
            cases.append(
                BenchCase(name: "\(label): folders first on", budget: budget, unit: .milliseconds) {
                    try await time(.foldersFirst, in: $0 ?? path)
                })
        }
        cases.append(
            BenchCase(name: "W2: sort key for Size", budget: budget("B8"), unit: .milliseconds) {
                try await time(.sortBySize, in: $0 ?? w2Path)
            })
        return cases
    }()

    enum ViewChange: Sendable {
        case showHidden, hideHidden, foldersFirst, sortBySize

        /// The command that makes the change.
        var command: Command {
            switch self {
            case .showHidden, .hideHidden: ViewCommands.toggleHidden
            case .foldersFirst: ViewCommands.toggleFoldersFirst
            case .sortBySize: ViewCommands.sortBySize
            }
        }

        /// Whether `listing` shows the change.
        func isShown(in listing: Listing) -> Bool {
            switch self {
            case .showHidden: listing.showsHidden
            case .hideHidden: !listing.showsHidden
            case .foldersFirst: listing.foldersFirst
            case .sortBySize: listing.column == .size
            }
        }
    }

    /// `/`, whose hidden entries are what W5 is about.
    private static let w5Path = "/"
    private static let w2Path = Fixture(.w2).path.path

    private static func time(_ change: ViewChange, in path: String) async throws -> Double {
        let root = try TempRoot(prefix: "searcher-bench-view")
        defer {
            do {
                try root.remove()
            } catch {
                printError("removing \(root.folder.path): \(error)")
            }
        }
        return try await time(change, in: path, suiteName: root.suiteName)
    }

    @MainActor
    private static func time(_ change: ViewChange, in path: String, suiteName: String)
        async throws -> Double
    {
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw ViewBenchFailed(description: "UserDefaults refused the suite \(suiteName)")
        }
        let settings = Settings(defaults: defaults)
        // Hiding needs hidden files shown first; nothing observes the settings yet.
        settings.showHidden = change == .hideHidden
        let pane = Pane(
            location: Location(path: path), service: ListingService(),
            systemActions: NoSystemActions(), settings: settings)
        await waitUntil(pane) {
            switch $0.state {
            case .loaded, .offline, .denied, .failed: true
            case .loading, .partial, .cachedRefreshing, .slow: false
            }
        }
        guard case .loaded(let listing) = pane.state, listing.count > 0 else {
            throw ViewBenchFailed(description: "\(path) didn't list any rows: \(pane.state)")
        }
        let middle = ExactName(listing[listing.count / 2].name)
        pane.select(Selection([middle], cursor: middle))
        guard let binding = AppCommands.bindings.first(where: { $0.command == change.command })
        else { preconditionFailure("\(change.command.id) isn't registered") }

        let start = ContinuousClock.now
        binding.run(CommandContext(pane: pane))
        await waitUntil(pane) { pane in
            pane.state.listing.map(change.isShown) == true && pane.selection.isSettled
        }
        return milliseconds(.now - start)
    }

    /// Returns once `condition` holds for `pane`, checking after each of its changes.
    @MainActor
    static func waitUntil(_ pane: Pane, _ condition: @escaping @MainActor (Pane) -> Bool)
        async
    {
        guard !condition(pane) else { return }
        await withCheckedContinuation { continuation in
            pane.onChange = { [unowned pane] in
                guard condition(pane) else { return }
                pane.onChange = nil
                continuation.resume()
            }
        }
    }

    struct ViewBenchFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// The bench opens nothing.
    @MainActor
    final class NoSystemActions: SystemActions {
        func openFile(_ url: URL) {
            preconditionFailure("the bench asked to open \(url.path)")
        }

        func openURL(_ url: URL) {
            preconditionFailure("the bench asked to open \(url)")
        }

        func copyToPasteboard(_ text: String) {
            preconditionFailure("the bench asked to copy \(text)")
        }

        func revealInFinder(_ urls: [URL]) {
            preconditionFailure("the bench asked to reveal \(urls)")
        }

        func open(_ folder: URL, inAppWithBundleID bundleID: String) {
            preconditionFailure("the bench asked to open \(folder.path) in \(bundleID)")
        }

        func open(_ urls: [URL], withApplicationAt application: URL) {
            preconditionFailure("the bench asked to open \(urls) with \(application.path)")
        }

        nonisolated func applicationURLs(toOpen type: UTType) -> [URL] {
            preconditionFailure("the bench asked for the apps that open \(type.identifier)")
        }

        nonisolated func defaultApplicationURL(toOpen type: UTType) -> URL? {
            preconditionFailure("the bench asked for the app that opens \(type.identifier)")
        }

        nonisolated func application(at url: URL) -> OpenWith.App {
            preconditionFailure("the bench asked to read the app at \(url.path)")
        }

        nonisolated func applicationIcon(at url: URL) async -> CGImage? {
            preconditionFailure("the bench asked for the icon of the app at \(url.path)")
        }
    }
}
