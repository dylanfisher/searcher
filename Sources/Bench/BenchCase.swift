import Base
import Foundation

/// One operation the runner measures, repeated `runs` times in a release build.
struct BenchCase: Sendable {
    /// Runs per case; docs/performance.md budgets are the p95 of this many.
    static let runs = 20

    /// Every case the runner measures, in run order.
    static let registered: [BenchCase] =
        openFolder + list + viewSettings + filter + listingCache + folderSize + fuzzyMatch
        + folderEvents + idle

    let name: String
    /// The budget the p95 is checked against; nil for a case that is only reported.
    let budget: Budget?
    /// The copy rate the p95 is checked against, for a copy case; nil for every other case.
    let floor: CopyFloor?
    /// What each sample is in: the budget's unit when there is a budget.
    let unit: Budget.Unit
    /// One run, returning its sample in `unit`. A run measures its own span, so it can stop the
    /// clock at a point and still wait for its work to finish before the next run starts.
    /// `folder` is the `--path` folder when one was given, else nil and the case uses its own
    /// workload.
    let run: @Sendable (_ folder: String?) async throws -> Double
    /// How many times `measure` runs the case.
    let runs: Int
    /// Work done once, untimed, before the first run: it makes the first run start in the same
    /// state as the rest. Nil for most cases.
    let warmUp: (@Sendable (_ folder: String?) async throws -> Void)?

    init(
        name: String, budget: Budget?, floor: CopyFloor? = nil, unit: Budget.Unit,
        runs: Int = BenchCase.runs,
        warmUp: (@Sendable (_ folder: String?) async throws -> Void)? = nil,
        run: @escaping @Sendable (_ folder: String?) async throws -> Double
    ) {
        if let budget {
            precondition(
                budget.unit == unit,
                "\(name) measures \(unit) against \(budget.id) in \(budget.unit)")
        }
        self.name = name
        self.budget = budget
        self.floor = floor
        self.unit = unit
        self.run = run
        self.runs = runs
        self.warmUp = warmUp
    }

    /// Runs `warmUp` if the case has one, then the case `runs` times (`BenchCase.runs` unless the case
    /// sets fewer).
    func measure(folder: String?) async throws -> Samples {
        try await warmUp?(folder)
        var samples: [Double] = []
        for _ in 0..<runs {
            samples.append(try await run(folder))
        }
        return Samples(samples)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }
}
