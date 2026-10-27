import Base
import Foundation

/// The shares each server lists, per `ShareRequest`: the last result of each, and at most one
/// run in flight, which a second asker joins. Names are kept `namesLifetime` and a failure
/// `failureBackoff`, so an ask within those times starts nothing. A run is started and waited
/// for on `BlockingCallThread`s; it ends at `LoadTimeouts.giveUp` as `unreachable`, and when its
/// last asker is cancelled. Only the state lives on the main actor. Nothing polls, and nothing is
/// written to disk (docs/decisions/0115-server-shares.md).
@MainActor
public final class ServerShares {
    /// How long a list of names is answered from the cache.
    public static let namesLifetime: Duration = .seconds(30)
    /// How long a failure is answered from the cache, so a rejected password on a server whose
    /// mounts change often doesn't start a process per change.
    public static let failureBackoff: Duration = .seconds(10)

    /// Names a request last listed, and when.
    public struct Cached: Equatable, Sendable {
        public let names: [String]
        /// The shares left out of `names` for their names (`ShareNames.isUsable`).
        public let unusableCount: Int
        /// When they were listed, by the system's clock, for the age a pane shows.
        public let listedAt: Date
    }

    private struct Entry {
        let result: Result<ShareList, ShareListError>
        /// When it was listed, as `elapsed` gives it.
        let listedAt: Duration
        /// When it was listed, by the system's clock.
        let listedDate: Date
    }

    /// One run of the enumerator and the askers waiting for it.
    private final class Run {
        var askers: [Int: CheckedContinuation<Result<ShareList, ShareListError>?, Never>] = [:]
        /// The enumerator's run, once it has started.
        var enumeration: (any ShareEnumeration)?
        /// Whether its askers have been answered or let go, after which nothing it returns is
        /// kept.
        var isOver = false
        /// Whether its server was forgotten while it ran, so what it returns goes to its askers
        /// and isn't kept.
        var isForgotten = false
        var timeout: Task<Void, Never>?
    }

    private let enumerator: any ShareEnumerator
    /// Time on the clock since the service was made.
    private let elapsed: @Sendable () -> Duration
    /// Starts a wait of the given length on the clock, taking the deadline at once, and returns
    /// the wait.
    private let startWait: @Sendable (Duration) -> @Sendable () async throws -> Void
    private var entries: [ShareRequest: Entry] = [:]
    private var runs: [ShareRequest: Run] = [:]
    private var nextAsker = 0
    private var observers: [Observer] = []

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    public init<C: Clock<Duration>>(
        enumerator: any ShareEnumerator = SmbutilShares(), clock: C = ContinuousClock()
    ) {
        self.enumerator = enumerator
        let start = clock.now
        elapsed = { start.duration(to: clock.now) }
        startWait = { duration in
            let deadline = clock.now.advanced(by: duration)
            return { try await clock.sleep(until: deadline, tolerance: nil) }
        }
    }

    /// `request`'s share names, or why they couldn't be listed: from the cache within its time,
    /// else from the run in flight for `request`, started if there is none. Nil when the asking
    /// task was cancelled, or `stop()` was called, before the run ended.
    public func names(for request: ShareRequest) async -> Result<ShareList, ShareListError>? {
        if let entry = entries[request] {
            let lifetime =
                switch entry.result {
                case .success: Self.namesLifetime
                case .failure: Self.failureBackoff
                }
            if elapsed() - entry.listedAt < lifetime { return entry.result }
        }
        nextAsker += 1
        let asker = nextAsker
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let run = runs[request] ?? start(request)
                run.askers[asker] = continuation
                // A task cancelled before this ran has had its handler run already, which hops
                // here after this.
            }
        } onCancel: {
            Task { @MainActor in self.leave(request, asker: asker) }
        }
    }

    /// The names `request` last listed, however long ago, and when; nil when it listed none, or
    /// its last run failed.
    public func cachedNames(for request: ShareRequest) -> Cached? {
        guard let entry = entries[request], case .success(let list) = entry.result else {
            return nil
        }
        return Cached(
            names: list.names, unusableCount: list.unusableCount, listedAt: entry.listedDate)
    }

    /// Drops what every user's request of `server` last listed, as when the server has no share
    /// mounted any more. A run of it in flight still answers its askers, and what it returns
    /// isn't kept; an ask made before it ends joins it, and gets its answer uncached.
    public func forget(_ server: Server) {
        entries = entries.filter { $0.key.server != server }
        for (request, run) in runs where request.server == server { run.isForgotten = true }
    }

    /// Runs `handler` each time `relistServers()` is called, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// Tells every pane at a server to list it again, as the app becomes active, since a share
    /// may have been added on the server. Each asks with `names(for:)`, so only a request whose
    /// entry is past its time starts a run.
    public func relistServers() {
        observers.removeAll { $0.owner == nil }
        for observer in observers { observer.handler() }
    }

    /// Ends every run, and answers each asker with nil. Called as the app quits.
    public func stop() {
        for (request, run) in runs { end(run, of: request) }
    }

    /// The askers waiting for `request`'s run, for tests.
    func askers(of request: ShareRequest) -> Int {
        runs[request]?.askers.count ?? 0
    }

    /// Starts a run for `request`: the enumerator starts and is waited for on
    /// `BlockingCallThread`s, and the run gives up at `LoadTimeouts.giveUp`.
    private func start(_ request: ShareRequest) -> Run {
        let run = Run()
        runs[request] = run
        let wait = startWait(LoadTimeouts.giveUp)
        run.timeout = Task { [weak self] in
            do {
                try await wait()
            } catch {
                // Cancelled: the run ended first.
                return
            }
            guard let self, !run.isOver else { return }
            run.enumeration?.terminate()
            self.finish(run, of: request, with: .failure(.unreachable))
        }
        let enumerator = enumerator
        Task { [weak self] in
            let started = await BlockingCallThread.run {
                () -> Result<any ShareEnumeration, ShareListError> in
                Result { () throws(ShareListError) in try enumerator.start(request) }
            }
            switch started {
            case .failure(let error):
                self?.finish(run, of: request, with: .failure(error))
            case .success(let enumeration):
                run.enumeration = enumeration
                // Its askers left, or it gave up, while it started.
                if run.isOver { enumeration.terminate() }
                let result = await BlockingCallThread.run { enumeration.wait() }
                self?.finish(run, of: request, with: result)
            }
        }
        return run
    }

    /// Keeps `result` as `request`'s and answers `run`'s askers with it, unless the run is over.
    private func finish(
        _ run: Run, of request: ShareRequest, with result: Result<ShareList, ShareListError>
    ) {
        guard !run.isOver else { return }
        if !run.isForgotten {
            entries[request] = Entry(result: result, listedAt: elapsed(), listedDate: Date())
        }
        close(run, of: request)
        for asker in run.askers.values { asker.resume(returning: result) }
        run.askers = [:]
    }

    /// Answers `asker` with nil, and ends `request`'s run if it was the last asker.
    private func leave(_ request: ShareRequest, asker: Int) {
        guard let run = runs[request], let continuation = run.askers.removeValue(forKey: asker)
        else { return }
        continuation.resume(returning: nil)
        if run.askers.isEmpty { end(run, of: request) }
    }

    /// Ends `run` without keeping what it returns, and answers its askers with nil.
    private func end(_ run: Run, of request: ShareRequest) {
        guard !run.isOver else { return }
        close(run, of: request)
        run.enumeration?.terminate()
        for asker in run.askers.values { asker.resume(returning: nil) }
        run.askers = [:]
    }

    /// Marks `run` over, so a later ask of `request` starts another.
    private func close(_ run: Run, of request: ShareRequest) {
        run.isOver = true
        run.timeout?.cancel()
        if runs[request] === run { runs[request] = nil }
    }
}
