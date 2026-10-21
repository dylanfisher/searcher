import Base
import Foundation

/// One operation the runner times, repeated `runs` times in a release build.
struct BenchCase: Sendable {
    /// Runs per case; docs/performance.md budgets are the p95 of this many.
    static let runs = 20

    /// Every case the runner times, in run order.
    static let registered: [BenchCase] = []

    let name: String
    /// The budget the p95 is checked against; nil for a case that is only reported.
    let budget: Budget?
    /// One run. `folder` is the `--path` folder when one was given, else nil and the case uses
    /// its own workload.
    let body: @Sendable (_ folder: String?) async throws -> Void

    /// Times `runs` runs of the body, in milliseconds.
    func measure(folder: String?) async throws -> Samples {
        let clock = ContinuousClock()
        var milliseconds: [Double] = []
        for _ in 0..<Self.runs {
            let elapsed = try await clock.measure { try await body(folder) }
            milliseconds.append(
                Double(elapsed.components.attoseconds) / 1e15
                    + Double(elapsed.components.seconds) * 1000)
        }
        return Samples(milliseconds)
    }
}
