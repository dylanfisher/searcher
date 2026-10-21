import Foundation
import Testing

@testable import Bench

@Test func budgetsMatchPerformanceDoc() throws {
    let doc = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/performance.md")
    let documented = try documentedBudgets(String(contentsOf: doc, encoding: .utf8))
    let inCode = Dictionary(
        uniqueKeysWithValues: Budget.all.map { ($0.id, "\($0.limit) \($0.unit.rawValue)") })
    // B1–B11, with two numbers each for B2 and B5; guards against the parser finding nothing.
    #expect(documented.count == 13)
    #expect(inCode == documented)
}

@Test func printsB10As50() throws {
    #expect(try Budget.named("B10").formattedLimit == "50")
}

@Test func unknownIDFailsNamingIt() {
    #expect {
        try Budget.named("B99")
    } throws: { error in
        String(describing: error).contains("B99")
    }
}

/// Reads the budget table in docs/performance.md into `id → "<number> <unit>"`, with seconds
/// converted to ms. A row with one number per workload gives one entry per workload, `B2.W1`.
private func documentedBudgets(_ markdown: String) throws -> [String: String] {
    var budgets: [String: String] = [:]
    for line in markdown.split(separator: "\n") where line.hasPrefix("| B") {
        let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        // The measurement table also has rows starting with B; budget rows are `| B<n> |`.
        let id = cells[0]
        guard id.wholeMatch(of: /B\d+/) != nil else { continue }
        let workloads = cells[2].components(separatedBy: " / ")
        let limits = cells[3].components(separatedBy: " / ")
        for (index, limit) in limits.enumerated() {
            let key = limits.count == 1 ? id : "\(id).\(workloads[index].prefix(2))"
            budgets[key] = try normalized(limit)
        }
    }
    return budgets
}

private func normalized(_ limit: String) throws -> String {
    let words = limit.split(separator: " ")
    let number = try #require(Int(words[words.count - 2]))
    switch words[words.count - 1] {
    case "s": return "\(number * 1000) ms"
    case let unit: return "\(number) \(unit)"
    }
}
