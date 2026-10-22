import Base
import Foundation

/// The UI bench's raw samples checked against their budgets: the p95 of each span. Stalls are
/// reported, not budgeted: B10 is about a share that is slow or gone (W6), which this run doesn't
/// open, and the plan asks only for the stall count here.
struct UIBenchReport {
    /// Relative to the repository root, where `scripts/bench` runs the binary.
    static let path = ".build/bench-ui.json"
    /// App processes per run: each gives one sample of every span but the key presses.
    static let launches = BenchCase.runs
    /// ↓ presses in the first launch, the count docs/performance.md times B6 over.
    static let keyPresses = 500
    /// A launch that takes longer than this, in seconds, is stuck and is stopped.
    static let launchTimeout = 120

    /// One case per span, in the order the app times them.
    let cases: [BenchReport.Case]
    /// Longest first.
    let stalls: [UIBenchRecord.Stall]

    init(record: UIBenchRecord) throws {
        let spans: [(name: String, budget: String, samples: [Double])] = [
            ("launch → first window frame", "B1", record.launch),
            ("open W1 → first rows frame", "B2.W1", record.openW1),
            ("open W2 → first rows frame", "B2.W2", record.openW2),
            ("W2 ↓ key → frame", "B6", record.keyDown),
            ("W2 Opt-↓/↑ key → frame", "B6", record.optionArrows),
            ("W2 Ctrl-Shift-↓ key → frame", "B6", record.controlShiftDown),
            ("W2 Fn-↓ key → frame", "B6", record.pageDown),
            ("W2 Shift-↓ key → frame", "B6", record.shiftDown),
            ("W2 Cmd-A key → frame", "B6", record.selectAll),
            ("W2 patch, all selected → frame", "B6", record.patchAllSelected),
            ("W2 reload landing, all selected → frame", "B6", record.reloadAllSelected),
            ("W2 sort change → frame", "B8", record.sortChange),
        ]
        cases = try spans.map { span in
            guard !span.samples.isEmpty else { throw NoSamples(span: span.name) }
            return BenchReport.Case(
                name: span.name, budget: try Budget.named(span.budget), unit: .milliseconds,
                samples: Samples(span.samples))
        }
        stalls = record.stalls.sorted { $0.milliseconds > $1.milliseconds }
    }

    var overBudget: [BenchReport.Case] { cases.filter(\.overBudget) }
    var passed: Bool { overBudget.isEmpty }

    /// One line per span, as the harness prints them, then the stalls with the span each fell in.
    var text: String {
        var lines = cases.map { line(for: $0) }
        let longest = stalls.first.map { ", longest \(format($0.milliseconds)) ms" } ?? ""
        lines.append("stalls: \(stalls.count)\(longest) (B10, reported only)")
        lines += stalls.map { "  \(format($0.milliseconds)) ms in \($0.span)" }
        return lines.joined(separator: "\n")
    }

    struct NoSamples: Error, CustomStringConvertible {
        let span: String
        var description: String { "the UI bench recorded no samples for \(span)" }
    }
}
