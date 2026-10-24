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
        /// The copy rate a copy case is held to, in place of a budget; nil for every other case.
        let floor: CopyFloor?
        /// Whether a median under `floor` fails the run; false on CI, where it is reported only.
        let floorEnforced: Bool
        let unit: Budget.Unit
        /// Every run in `unit`, ascending.
        let samples: [Double]
        let median: Double
        let p95: Double
        let overBudget: Bool

        init(
            name: String, budget: Budget?, floor: CopyFloor? = nil, unit: Budget.Unit,
            samples: Samples,
            environment: [String: String] = ProcessInfo.processInfo.environment
        ) {
            self.name = name
            self.budget = budget
            self.floor = floor
            floorEnforced = CopyFloor.isEnforced(environment: environment)
            self.unit = unit
            self.samples = samples.sorted
            median = samples.median
            p95 = samples.p95
            overBudget =
                (budget.map { samples.p95 > Double($0.limit) } ?? false)
                || (floorEnforced && floor?.isMissed(byMilliseconds: samples.median) == true)
        }

        /// Whether the median is under `floor` on CI, where that is reported and doesn't fail.
        var underFloorReportedOnly: Bool {
            !floorEnforced && floor?.isMissed(byMilliseconds: median) == true
        }

        /// The statistic the case is judged on and its value: the median for a floor case, whose
        /// floor is a median, else the p95 that budgets are.
        var judged: (label: String, value: Double) {
            floor == nil ? ("p95", p95) : ("median", median)
        }

        /// The line naming this case as a miss, "<prefix>: name p95 12 ms, budget ...", prefix being
        /// "over budget" unless the caller qualifies it.
        func missText(prefix: String = "over budget") -> String {
            "\(prefix): \(name) \(judged.label) \(format(judged.value)) \(unit.rawValue), \(limit)"
        }

        /// What the case is judged against, as the reports print it.
        var limit: String {
            if let floor {
                let mode = floorEnforced ? "" : ", reported only on CI"
                return "floor \(floor.id) \(floor.megabytesPerSecond) MB/s\(mode)"
            }
            return "budget " + (budget.map(describe) ?? "none")
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
