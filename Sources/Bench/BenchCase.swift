import Base
import Foundation

/// One operation the runner measures, repeated `runs` times in a release build.
struct BenchCase: Sendable {
    /// Runs per case; docs/performance.md budgets are the p95 of this many.
    static let runs = 20

    /// Every case the runner measures, in run order.
    static let registered: [BenchCase] = openFolder

    let name: String
    /// The budget the p95 is checked against; nil for a case that is only reported.
    let budget: Budget?
    /// What each sample is in: the budget's unit when there is a budget.
    let unit: Budget.Unit
    /// One run, returning its sample in `unit`. A run measures its own span, so it can stop the
    /// clock at a point and still wait for its work to finish before the next run starts.
    /// `folder` is the `--path` folder when one was given, else nil and the case uses its own
    /// workload.
    let run: @Sendable (_ folder: String?) async throws -> Double

    init(
        name: String, budget: Budget?, unit: Budget.Unit,
        run: @escaping @Sendable (_ folder: String?) async throws -> Double
    ) {
        if let budget {
            precondition(
                budget.unit == unit,
                "\(name) measures \(unit) against \(budget.id) in \(budget.unit)")
        }
        self.name = name
        self.budget = budget
        self.unit = unit
        self.run = run
    }

    /// Runs the case `runs` times.
    func measure(folder: String?) async throws -> Samples {
        var samples: [Double] = []
        for _ in 0..<Self.runs {
            samples.append(try await run(folder))
        }
        return Samples(samples)
    }

    static func milliseconds(_ duration: Duration) -> Double {
        Double(duration.components.attoseconds) / 1e15 + Double(duration.components.seconds) * 1000
    }
}
