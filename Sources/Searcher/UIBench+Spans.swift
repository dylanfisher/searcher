import AppKit
import Base
import Browser
import Interface
import os

extension UIBench {
    /// Navigates the pane to `path` and times it to the frame with the first rows: its cached
    /// rows when `cached`, which fails when the folder's own rows come first. `others` are
    /// navigated there first, in the same pass, so their loads are asked before the pane's.
    func open(
        _ path: String, _ name: StaticString, cached: Bool = false, others: [Pane] = []
    ) async throws -> Double {
        try requireVisible()
        let pane = try requirePane()
        let window = try requireWindow()
        let start = FrameCommitTimer.now
        let interval = begin(name)
        let shown: Result<Double, Failure> = await withCheckedContinuation { continuation in
            whenShown = { [self] pane in
                let listing: Listing
                switch pane.state {
                case .loading, .slow:
                    return false
                case .partial(let rows), .loaded(let rows):
                    guard !cached else {
                        continuation.resume(
                            returning: .failure(
                                Failure(
                                    "\(path) showed its own rows before cached ones: it isn't on a "
                                        + "network volume, or the cache didn't keep it")))
                        return true
                    }
                    listing = rows
                case .cachedRefreshing(let rows, _):
                    guard cached else {
                        preconditionFailure(
                            "only the revisit scenario's listing service has a cache")
                    }
                    listing = rows
                case .offline:
                    continuation.resume(returning: .failure(Failure("\(path) went offline")))
                    return true
                case .denied(let error), .failed(let error):
                    continuation.resume(
                        returning: .failure(Failure("\(path) could not be listed: \(error)")))
                    return true
                case .notConnected, .serverListed:
                    preconditionFailure("the bench lists folders, never a server")
                }
                guard listing.count > 0 else {
                    continuation.resume(
                        returning: .failure(Failure("\(path) is empty, so no rows were timed")))
                    return true
                }
                timeFrame(from: start, in: window, name, interval) {
                    continuation.resume(returning: .success($0))
                }
                return true
            }
            for other in others {
                other.navigate(to: Location(path: path))
            }
            pane.navigate(to: Location(path: path))
        }
        return try shown.get()
    }

    /// The time from `start` to the commit of the window's next drawn frame, ending `interval`
    /// there.
    func frame(
        from start: TimeInterval, _ name: StaticString, _ interval: OSSignpostIntervalState
    ) async throws -> Double {
        let window = try requireWindow()
        return await withCheckedContinuation { continuation in
            timeFrame(from: start, in: window, name, interval) {
                continuation.resume(returning: $0)
            }
        }
    }

    /// Starts timing the frame now, in the pass that made the change.
    func timeFrame(
        from start: TimeInterval, in window: NSWindow, _ name: StaticString,
        _ interval: OSSignpostIntervalState, _ done: @escaping @MainActor (Double) -> Void
    ) {
        FrameCommitTimer.time(from: start, in: window) { [self] elapsed in
            signposter.endInterval(name, interval)
            spans.append(TimedSpan(name: "\(name)", start: spanStart, end: .now))
            done(Self.milliseconds(elapsed))
        }
    }

    /// Starts the signpost interval for a span and notes when it started, to file stalls by.
    func begin(_ name: StaticString) -> OSSignpostIntervalState {
        spanStart = .now
        return signposter.beginInterval(name)
    }

    func paneShown() {
        guard let check = whenShown, let pane = controller?.paneViewController.pane else { return }
        if check(pane) { whenShown = nil }
    }

    /// Waits until the window has drawn everything it needed to.
    func waitUntilDrawn() async throws {
        let window = try requireWindow()
        await withCheckedContinuation { continuation in
            FrameCommitTimer.time(from: FrameCommitTimer.now, in: window) { _ in
                continuation.resume()
            }
        }
    }

    /// Waits for `target`, else the window's pane, to hold its complete listing.
    func waitUntilLoaded(_ target: Pane? = nil) async throws {
        let pane = try target ?? requirePane()
        let deadline = ContinuousClock.now + .seconds(30)
        while true {
            switch pane.state {
            case .loaded: return
            case .denied(let error), .failed(let error):
                throw Failure("\(pane.location.folderPath) could not be listed: \(error)")
            case .offline:
                throw Failure("\(pane.location.folderPath) went offline")
            case .notConnected, .serverListed:
                preconditionFailure("the bench lists folders, never a server")
            case .loading, .partial, .cachedRefreshing, .slow: break
            }
            guard ContinuousClock.now < deadline else {
                throw Failure("\(pane.location.folderPath) did not finish loading in 30 s")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for `trail` to show `count` columns, as it does once the keys pause for
    /// `ColumnTrail.openDelay`.
    func waitForColumns(_ count: Int, in trail: ColumnTrail) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while trail.columns.count != count {
            guard ContinuousClock.now < deadline else {
                throw Failure(
                    "column view did not reach \(count) columns in 30 s: "
                        + "\(trail.columns.map(\.pane.location.folderPath))")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Waits for `target`, else the window's pane, to finish naming or resolving a selection off
    /// the main thread.
    func waitUntilSettled(_ target: Pane? = nil) async throws {
        let pane = try target ?? requirePane()
        let deadline = ContinuousClock.now + .seconds(30)
        while !pane.selection.isSettled {
            guard ContinuousClock.now < deadline else {
                throw Failure("the selection did not settle in 30 s: \(pane.selection)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
