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
