import Base
import Foundation

/// What changed between the previous run's report and this one, and whether this run passes.
/// The comparison only reports; the one thing that fails is a case over its own budget.
struct RegressionReport {
    /// A case is reported when its median is more than this fraction above the previous median.
    /// The median, not the p95: a p95 of 20 runs is the second slowest, and of the 5-run idle cases
    /// the slowest, so one noisy run on a shared runner would trip it. The p95 is what the budget
    /// check uses.
    static let threshold = 0.10

    struct Slower: Equatable {
        let name: String
        let unit: Budget.Unit
        let previous: Double
        let current: Double
        var percent: Double { (current / previous - 1) * 100 }
    }

    let hasPrevious: Bool
    let slower: [Slower]
    let newCases: [String]
    let missingCases: [String]
    let unitChanged: [String]
    let overBudget: [BenchReport.Case]

    var passed: Bool { overBudget.isEmpty }

    init(previous: BenchReport?, current: BenchReport) {
        hasPrevious = previous != nil
        overBudget = current.overBudget
        let before = Dictionary(
            (previous?.cases ?? []).map { ($0.name, $0) }, uniquingKeysWith: { _, last in last })
        var slower: [Slower] = []
        var newCases: [String] = []
        var unitChanged: [String] = []
        for now in current.cases where previous != nil {
            guard let was = before[now.name] else {
                newCases.append(now.name)
                continue
            }
            guard was.unit == now.unit else {
                unitChanged.append(now.name)
                continue
            }
            // A zero median has no percentage to compare against.
            guard was.median > 0, now.median > was.median * (1 + Self.threshold) else { continue }
            slower.append(
                Slower(name: now.name, unit: now.unit, previous: was.median, current: now.median))
        }
        let currentNames = Set(current.cases.map(\.name))
        self.slower = slower
        self.newCases = newCases
        self.unitChanged = unitChanged
        missingCases = (previous?.cases ?? []).map(\.name).filter { !currentNames.contains($0) }
    }

    /// The report as printed, one finding per line.
    var text: String {
        var lines: [String] = []
        if !hasPrevious {
            lines.append("no previous report to compare against")
        }
        let limit = Int(Self.threshold * 100)
        for item in slower {
            lines.append(
                "slower: \(item.name)  median \(format(item.previous)) -> \(format(item.current)) "
                    + "\(item.unit.rawValue)  +\(String(format: "%.1f", item.percent))%")
        }
        if hasPrevious && slower.isEmpty {
            lines.append("no case's median is more than \(limit)% slower than the previous run")
        }
        lines += newCases.map { "new case: \($0)" }
        lines += missingCases.map { "not in this run: \($0)" }
        lines += unitChanged.map { "unit changed: \($0), not compared" }
        for miss in overBudget {
            let budget = miss.budget.map(describe) ?? "none"
            lines.append(
                "over budget: \(miss.name) p95 \(format(miss.p95)) \(miss.unit.rawValue), budget \(budget)"
            )
        }
        return lines.joined(separator: "\n")
    }
}

extension Budget: Decodable {
    private enum StoredKeys: String, CodingKey {
        case id, limit, unit
    }

    /// Written by hand because Budget.swift declares only `Encodable`, and a conformance added in
    /// another file can't be synthesized.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: StoredKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            limit: try container.decode(Int.self, forKey: .limit),
            unit: try container.decode(Unit.self, forKey: .unit))
    }
}

extension BenchReport {
    static func read(from path: String) throws -> BenchReport {
        try JSONDecoder().decode(BenchReport.self, from: Data(contentsOf: URL(filePath: path)))
    }
}

extension RegressionReport {
    /// What a CI run keeps of the UI bench for the next run: each case's p95 in the last
    /// `UI.stableRuns` runs on `branch`, newest last, and whether the case is enforced yet. It
    /// travels as a file in the run's artifact, next to `bench-ui.json`.
    struct UIHistory: Codable, Equatable {
        /// Relative to the repository root, where `scripts/bench` runs the binary.
        static let path = ".build/bench-ui-history.json"

        struct Entry: Codable, Equatable {
            let name: String
            let p95s: [Double]
            /// Set once the p95s have been steady, and never cleared: a later run that misses its
            /// budget is the regression the enforcement is there to catch.
            let enforced: Bool
        }

        let branch: String
        let cases: [Entry]

        func write(to path: String) throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try AtomicWrite.write(try encoder.encode(self), to: URL(filePath: path))
        }

        static func read(from path: String) throws -> UIHistory {
            try JSONDecoder().decode(UIHistory.self, from: Data(contentsOf: URL(filePath: path)))
        }
    }

    /// One CI run of the UI bench judged against the history the previous run kept. A UI case is
    /// report-only until its p95 has stayed within `RegressionReport.threshold` across
    /// `stableRuns` consecutive runs on one branch, because frame timing on a shared runner is
    /// noisier than listing time (decision 0002). From then on its p95 over budget fails the run.
    struct UI {
        static let stableRuns = 3

        struct Judged {
            let result: BenchReport.Case
            let p95s: [Double]
            let enforced: Bool
            let enforcedThisRun: Bool
            /// How far the largest p95 kept is above the smallest, in percent, once two are kept.
            var spread: Double? {
                guard p95s.count > 1, let low = p95s.min(), let high = p95s.max(), low > 0 else {
                    return nil
                }
                return (high / low - 1) * 100
            }
        }

        /// The previous history's branch when it was another one, else nil.
        let previousBranch: String?
        let hasPrevious: Bool
        /// Why the previous history file couldn't be read, when it couldn't.
        let unreadablePrevious: String?
        let cases: [Judged]
        let missingCases: [String]
        /// What this run keeps for the next one.
        let history: UIHistory

        var passed: Bool { !cases.contains { $0.enforced && $0.result.overBudget } }

        /// Throws when `current` doesn't hold exactly one run's launches: a run that stopped
        /// partway has no p95 to compare, and more launches than one run makes is not one run's
        /// record. `unreadablePrevious` is why the previous history couldn't be read, which the
        /// report states; `previous` is then nil.
        init(
            previous: UIHistory?, unreadablePrevious: String? = nil, current: UIBenchRecord,
            branch: String
        ) throws {
            guard current.launch.count >= UIBenchReport.launches else {
                throw Incomplete(launches: current.launch.count)
            }
            guard current.launch.count == UIBenchReport.launches else {
                throw TooManyLaunches(launches: current.launch.count)
            }
            let report = try UIBenchReport(record: current, scenario: nil)
            hasPrevious = previous != nil
            self.unreadablePrevious = unreadablePrevious
            previousBranch = previous.flatMap { $0.branch == branch ? nil : $0.branch }
            let before = Dictionary(
                (previous?.cases ?? []).map { ($0.name, $0) }, uniquingKeysWith: { _, last in last }
            )
            // Runs count on one branch, so a history from another one keeps only what it enforced.
            let sameBranch = previous?.branch == branch
            cases = report.cases.map { result in
                let was = before[result.name]
                let kept = sameBranch ? was?.p95s ?? [] : []
                let p95s = Array((kept + [result.p95]).suffix(Self.stableRuns))
                // `p95s` holds this run's p95, so starting from it gives the exact bounds.
                let low = p95s.reduce(result.p95, min)
                let high = p95s.reduce(result.p95, max)
                let steady =
                    p95s.count == Self.stableRuns
                    && high <= low * (1 + RegressionReport.threshold)
                let already = was?.enforced ?? false
                return Judged(
                    result: result, p95s: p95s, enforced: already || steady,
                    enforcedThisRun: !already && steady)
            }
            let currentNames = Set(report.cases.map(\.name))
            missingCases = (previous?.cases ?? []).map(\.name).filter { !currentNames.contains($0) }
            history = UIHistory(
                branch: branch,
                cases: cases.map {
                    UIHistory.Entry(name: $0.result.name, p95s: $0.p95s, enforced: $0.enforced)
                })
        }

        /// The report as printed: what the history held, then one line per case saying whether
        /// it is enforced, then each case over budget and whether that fails the run.
        var text: String {
            var lines: [String] = []
            if let unreadablePrevious {
                lines.append(
                    "previous UI history unreadable: \(unreadablePrevious), discarded; runs count "
                        + "from this one")
            } else if !hasPrevious {
                lines.append("no previous UI history: runs count from this one")
            }
            if let previousBranch {
                lines.append(
                    "previous UI history is from branch \(previousBranch): its enforced cases stay "
                        + "enforced, and runs count from this one")
            }
            let limit = Int(RegressionReport.threshold * 100)
            for item in cases {
                let mode: String
                if item.enforcedThisRun {
                    mode =
                        "enforced from this run: p95 within \(limit)% across \(Self.stableRuns) runs"
                } else if item.enforced {
                    mode = "enforced"
                } else {
                    let spread = item.spread.map { ", spread \(String(format: "%.1f", $0))%" } ?? ""
                    mode =
                        "report-only: \(item.p95s.count) of \(Self.stableRuns) runs kept\(spread); "
                        + "enforced once \(Self.stableRuns) are within \(limit)%"
                }
                lines.append("\(line(for: item.result))  \(mode)")
            }
            lines += missingCases.map { "not in this run: \($0)" }
            for item in cases where item.result.overBudget {
                let miss = item.result
                let budget = miss.budget.map(describe) ?? "none"
                let label = item.enforced ? "over budget" : "over budget (report-only)"
                lines.append(
                    "\(label): \(miss.name) p95 \(format(miss.p95)) \(miss.unit.rawValue), budget \(budget)"
                )
            }
            return lines.joined(separator: "\n")
        }

        struct Incomplete: Error, CustomStringConvertible {
            let launches: Int
            var description: String {
                "the UI bench record holds \(launches) of \(UIBenchReport.launches) launches: the run did not finish"
            }
        }

        struct TooManyLaunches: Error, CustomStringConvertible {
            let launches: Int
            var description: String {
                "the UI bench record holds \(launches) launches, more than the \(UIBenchReport.launches) one run makes, so it is not one run's record"
            }
        }
    }
}
