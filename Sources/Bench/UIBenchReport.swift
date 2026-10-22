import Base
import Foundation

/// The UI bench's raw samples checked against their budgets: the p95 of each span. In the CI run
/// and every scenario but `column-walk`, stalls are reported, not budgeted: B10 is about a share
/// that is slow or gone (W6), which those runs don't open, and the plan asks only for the stall
/// count there. `column-walk` walks a share, so a stall outside the launch fails it.
struct UIBenchReport {
    /// Relative to the repository root, where `scripts/bench` runs the binary.
    static let path = ".build/bench-ui.json"
    /// App processes per run: each gives one sample of every span but the key presses.
    static let launches = BenchCase.runs
    /// ↓ presses in the first launch, the count docs/performance.md times B6 over. Also the ↓
    /// presses through W2's first column in column view, and in the focused pane of a split.
    static let keyPresses = 500
    /// A launch that takes longer than this, in seconds, is stuck and is stopped.
    static let launchTimeout = 120

    /// Where a run writes its record: a scenario's own file, so it never stands in for the CI
    /// run's record that `compare-ui` judges.
    static func path(for scenario: UIBenchOptions.Scenario?) -> String {
        scenario.map { ".build/bench-ui-\($0.rawValue).json" } ?? path
    }

    /// A scenario is one launch: each times a span many times over, or opens folders that are
    /// cold only once.
    static func launches(for scenario: UIBenchOptions.Scenario?) -> Int {
        scenario == nil ? launches : 1
    }

    /// The ↓ presses launch `launch` (from 0) of a run makes: the CI run's first launch and the
    /// scenarios that press keys on W2 press `keyPresses`, every other launch none.
    static func keyPresses(launch: Int, scenario: UIBenchOptions.Scenario?) -> Int {
        let pressesKeys = scenario == nil || scenario == .columnKeys || scenario == .splits
        return launch == 0 && pressesKeys ? keyPresses : 0
    }

    /// One case per span, in the order the app times them.
    let cases: [BenchReport.Case]
    /// Longest first.
    let stalls: [UIBenchRecord.Stall]
    /// B10 when stalls fail the run, nil when they are reported only.
    let stallBudget: Budget?

    init(record: UIBenchRecord, scenario: UIBenchOptions.Scenario?) throws {
        let columnKeys: [(name: String, budget: String, samples: [Double])] = [
            ("W2 column view ↓ through folders → frame", "B6", record.columnDown),
            ("W2 column view → key → frame", "B6", record.columnRight),
            ("W2 column view ← key → frame", "B6", record.columnLeft),
        ]
        let splits: [(name: String, budget: String, samples: [Double])] = [
            ("W2 two-pane split ↓ key → frame", "B6", record.splitDown),
            ("W2 4-pane grid ↓ key → frame", "B6", record.gridDown),
            ("open W2 in ten panes → focused first rows frame", "B2.W2", record.tenPaneOpen),
        ]
        let spans: [(name: String, budget: String, samples: [Double])]
        switch scenario {
        case nil:
            spans =
                [
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
                    (
                        "W2 patch adding a row, all selected → frame", "B6",
                        record.patchAddingAllSelected
                    ),
                    ("W2 click selecting half → frame", "B6", record.clickHalf),
                    ("W2 patch landing after Shift-↓ → frame", "B6", record.patchAfterShiftDown),
                    (
                        "W2 load landing after Cmd-A on first batch → frame", "B6",
                        record.loadAfterSelectAll
                    ),
                    ("W2 type-select key → frame", "B6", record.typeSelect),
                    ("W2 sort change → frame", "B8", record.sortChange),
                    ("W2 Cmd-Shift-. key → frame", "B8", record.hiddenToggle),
                    ("W2 folders first → frame", "B8", record.foldersFirstToggle),
                    ("W2 sort key → frame", "B8", record.sortKey),
                    ("W2 filter key → frame", "B7", record.filterKey),
                ] + columnKeys + splits
        case .columnKeys:
            spans = columnKeys
        case .splits:
            spans = splits
        case .cold:
            spans = [("cold open of a subfolder → first rows frame", "B3", record.coldOpen)]
        case .revisit:
            spans = [("revisit → cached rows frame", "B4", record.revisit)]
        case .columnWalk:
            spans = [("column walk key → frame", "B6", record.columnWalkKey)]
        }
        cases = try spans.map { span in
            guard !span.samples.isEmpty else { throw NoSamples(span: span.name) }
            return BenchReport.Case(
                name: span.name, budget: try Budget.named(span.budget), unit: .milliseconds,
                samples: Samples(span.samples))
        }
        stalls = record.stalls.sorted { $0.milliseconds > $1.milliseconds }
        stallBudget = scenario == .columnWalk ? try Budget.named("B10") : nil
        timesTenPanes = scenario == nil || scenario == .splits
    }

    /// Whether the run opens ten panes at once, whose stalls are counted on their own line.
    let timesTenPanes: Bool

    var overBudget: [BenchReport.Case] { cases.filter(\.overBudget) }

    /// The stalls that fail the run: none unless stalls are budgeted, and never the launch's,
    /// up to the end of its warm-up, which open no share.
    var stallsOverBudget: [UIBenchRecord.Stall] {
        guard stallBudget != nil else { return [] }
        return stalls.filter { !UIBenchRecord.launchSpans.contains($0.span) }
    }

    var passed: Bool { overBudget.isEmpty && stallsOverBudget.isEmpty }

    /// One line per span, as the harness prints them, then the stalls with the span each fell in.
    var text: String {
        var lines = cases.map { line(for: $0) }
        let longest = stalls.first.map { ", longest \(format($0.milliseconds)) ms" } ?? ""
        let judged =
            stallBudget.map { budget in
                "(\(describe(budget)))" + (stallsOverBudget.isEmpty ? "" : "  OVER BUDGET")
            } ?? "(B10, reported only)"
        lines.append("stalls: \(stalls.count)\(longest) \(judged)")
        lines += stalls.map { "  \(format($0.milliseconds)) ms in \($0.span)" }
        if timesTenPanes {
            // B10 while ten panes load, as the plan asks; reported, since no share is opened.
            let during = stalls.filter { UIBenchRecord.tenPaneSpans.contains($0.span) }
            let longest = during.first.map { ", longest \(format($0.milliseconds)) ms" } ?? ""
            lines.append(
                "stalls during the ten-pane load: \(during.count)\(longest) (B10, reported only)")
        }
        return lines.joined(separator: "\n")
    }

    struct NoSamples: Error, CustomStringConvertible {
        let span: String
        var description: String { "the UI bench recorded no samples for \(span)" }
    }
}
