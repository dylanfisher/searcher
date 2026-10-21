import Base
import Foundation

/// The results of one bench run, written as JSON so CI can keep it and compare runs.
struct BenchReport: Sendable, Codable {
    /// Relative to the repository root, where `scripts/bench` runs the binary.
    static let path = ".build/bench.json"

    struct Case: Sendable, Codable {
        let name: String
        /// Nil for a case that is only reported.
        let budget: Budget?
        let unit: Budget.Unit
        /// Every run in `unit`, ascending.
        let samples: [Double]
        let median: Double
        let p95: Double
        let overBudget: Bool

        init(name: String, budget: Budget?, unit: Budget.Unit, samples: Samples) {
            self.name = name
            self.budget = budget
            self.unit = unit
            self.samples = samples.sorted
            median = samples.median
            p95 = samples.p95
            overBudget = budget.map { samples.p95 > Double($0.limit) } ?? false
        }
    }

    let machine: MachineLoad
    let cases: [Case]

    var overBudget: [Case] { cases.filter(\.overBudget) }
    var passed: Bool { overBudget.isEmpty }

    func write(to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: URL(filePath: path), options: .atomic)
    }
}
