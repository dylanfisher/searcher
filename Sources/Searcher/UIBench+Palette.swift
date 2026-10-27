import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// The `palette` scenario: opens the palette over the window with
    /// `UIBenchOptions.paletteCandidates` folders added to its items, then types each of
    /// `UIBenchOptions.paletteQueries` into its emptied field, each key timed from its timestamp
    /// to the frame that shows the query's results (B11). The folders are made off the main
    /// thread, untimed, before the palette opens, as a typed path's listing makes its items. The
    /// panel is put over the window as Cmd-K puts it; the app stays inactive.
    func typeInPalette() async throws {
        let items = await Task.detached { Self.paletteFolders() }.value
        let controller = try requireController()
        controller.showPalette(adding: [FixedPaletteSource(items: items)])
        guard let palette = controller.palette, let panel = palette.window else {
            throw Failure("the palette didn't open over the bench window")
        }
        let content = palette.viewController
        // The first results, for the empty query, untimed; they may have shown already.
        if content.shownQuery != "" {
            try await paletteShows("", in: panel, content) {}
        }
        for query in UIBenchOptions.paletteQueries {
            for length in 1...query.count {
                let typed = String(query.prefix(length))
                let event = try keyEvent(
                    Key(characters: String(typed.suffix(1)), keyCode: 0, flags: []), in: panel)
                let interval = begin(Self.paletteKeySpan)
                record.paletteKey.append(
                    try await paletteShows(
                        typed, in: panel, content, timedFrom: event.timestamp, interval
                    ) { panel.sendEvent(event) })
            }
            let delete = Key(characters: "\u{7F}", keyCode: 51, flags: [])
            try await paletteShows("", in: panel, content) {
                for _ in query {
                    panel.sendEvent(try keyEvent(delete, in: panel))
                }
            }
        }
        palette.close()
    }

    private static let paletteKeySpan: StaticString = "palette key"

    /// Runs `change`, then waits until the palette shows `query`'s results, and with `start`
    /// times the frame that shows them, ending `interval` there.
    @discardableResult
    private func paletteShows(
        _ query: String, in panel: NSWindow, _ content: PaletteViewController,
        timedFrom start: TimeInterval? = nil, _ interval: OSSignpostIntervalState? = nil,
        _ change: () throws -> Void
    ) async throws -> Double {
        guard panel.isVisible else { throw Failure("the palette's panel isn't on screen") }
        return try await withCheckedThrowingContinuation { continuation in
            content.onShow = { [self, weak content] in
                guard let content, content.shownQuery == query else { return }
                content.onShow = nil
                guard let start, let interval else { return continuation.resume(returning: 0) }
                timeFrame(from: start, in: panel, Self.paletteKeySpan, interval) {
                    continuation.resume(returning: $0)
                }
            }
            do {
                try change()
            } catch {
                content.onShow = nil
                continuation.resume(throwing: error)
            }
        }
    }

    /// `UIBenchOptions.paletteCandidates` folders shaped like W3's package tree, as items the
    /// palette ranks with every other source's.
    private nonisolated static func paletteFolders() -> [PaletteItem] {
        let packages = [
            "react", "lodash", "babel-core", "webpack", "typescript", "eslint", "rxjs", "moment",
            "express", "jest", "libxml", "postcss",
        ]
        let leaves = ["map", "index", "lib", "dist", "util", "test", "src"]
        return (0..<UIBenchOptions.paletteCandidates).map { index in
            let package = packages[index % packages.count]
            let path =
                "/w3/node_modules/\(package)-\(index / 1_000)/pkg/src/"
                + "\(leaves[index % leaves.count])\(index)"
            return PaletteItem(id: .folder(path: path), title: path) {}
        }
    }
}

/// The `palette` scenario's folders, handed over on every key as a source that holds them in
/// memory would.
@MainActor
private struct FixedPaletteSource: PaletteSource {
    let items: [PaletteItem]

    func gather(_ query: String, deliver: @escaping @MainActor ([PaletteItem]) -> Void) {
        deliver(items)
    }

    func cancel() {}
}
