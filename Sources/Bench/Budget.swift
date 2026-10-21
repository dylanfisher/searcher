/// One budget from the table in docs/performance.md. This file is the only copy of the numbers in
/// code; `BudgetTests` fails when it and the table differ.
struct Budget: Sendable, Equatable, Encodable {
    enum Unit: String, Sendable, Codable {
        case milliseconds = "ms"
        case megabytes = "MB"
    }

    /// `B1`, or `B2.W1` for a budget with one number per workload.
    let id: String
    let limit: Int
    let unit: Unit

    static let all: [Budget] = [
        Budget(id: "B1", limit: 500, unit: .milliseconds),
        Budget(id: "B2.W1", limit: 50, unit: .milliseconds),
        Budget(id: "B2.W2", limit: 100, unit: .milliseconds),
        Budget(id: "B3", limit: 150, unit: .milliseconds),
        Budget(id: "B4", limit: 16, unit: .milliseconds),
        Budget(id: "B5.W2", limit: 500, unit: .milliseconds),
        Budget(id: "B5.W3", limit: 2000, unit: .milliseconds),
        Budget(id: "B6", limit: 16, unit: .milliseconds),
        Budget(id: "B7", limit: 50, unit: .milliseconds),
        Budget(id: "B8", limit: 150, unit: .milliseconds),
        Budget(id: "B9", limit: 60, unit: .megabytes),
        Budget(id: "B10", limit: 50, unit: .milliseconds),
        Budget(id: "B11", limit: 50, unit: .milliseconds),
    ]

    static func named(_ id: String) throws(UnknownID) -> Budget {
        guard let budget = all.first(where: { $0.id == id }) else { throw UnknownID(id: id) }
        return budget
    }

    /// The limit as scripts read it: the number alone, in the budget's unit.
    var formattedLimit: String { String(limit) }

    struct UnknownID: Error, CustomStringConvertible {
        let id: String
        var description: String {
            "unknown budget ID \(id); known IDs: \(Budget.all.map(\.id).joined(separator: ", "))"
        }
    }
}
