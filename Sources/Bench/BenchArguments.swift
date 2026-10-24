import Base
import Foundation

/// What one invocation of the runner does, parsed from its command line.
enum BenchArguments: Equatable {
    /// Print one budget's number and exit, for scripts that pass it on.
    case printBudget(Budget)
    /// Time every registered case, against `folder` when given, and the copy case to the disk
    /// image mounted at `image`, which scripts/bench attaches.
    case run(folder: String?, image: String? = nil)
    /// Sample the machine once and fail naming any busy process, so a caller can wait for idle.
    case checkIdle
    /// Open `folder` once and print the footprint it added in MB. The B9 case runs this in a fresh
    /// process for each sample.
    case footprintOfOpening(folder: String)
    /// Time listing 20 different subfolders of `folder`, once each (B3 cold).
    case coldChildren(folder: String)
    /// Compare two saved reports and fail only when `current` has a case over budget. A missing
    /// `previous` file is stated, not an error.
    case compare(previous: String, current: String)
    /// Launch the app bundle at `app` in its UI bench mode, opening `folder` as both workloads
    /// when given: the CI run, or one scenario. The CI run copies `w8`, W8 or its CI variant, to
    /// the disk image mounted at `image`, which scripts/bench attaches.
    case ui(
        app: String, folder: String?, scenario: UIBenchOptions.Scenario?, image: String? = nil,
        w8: Fixture.Workload = .w8)
    /// Check the free space the run the rest of the arguments ask for needs, and print the size
    /// of the disk image it copies to in MB and the folder to make it in, or 0 when it copies
    /// nothing. scripts/bench calls it before anything is written.
    indirect case diskImageSize(BenchArguments)
    /// Print what `--scenario` takes.
    case help
    /// Print `stallArguments()` on one line, for scripts that launch the app.
    case printStallArguments
    /// Judge the UI bench record `current` against the history file `previous` kept by the last
    /// CI run on `branch` (else `main`), write the next history, and fail only when an enforced
    /// case is over budget. A missing `previous` file is stated, not an error.
    case compareUI(previous: String, current: String, branch: String)

    /// The app's launch arguments that start its stall watchdog at B10.
    static func stallArguments() throws -> [String] {
        [StallWatchdog.thresholdArgument, try Budget.named("B10").formattedLimit]
    }

    /// The scenarios `--ui --scenario` runs, one line each; `scripts/bench --help` prints it.
    static var scenarioHelp: String {
        let lines = UIBenchOptions.Scenario.allCases.map { scenario in
            let summary: String
            switch scenario {
            case .columnKeys:
                summary =
                    "W2 in column view: ↓ through folder rows, each opening a column, then → and ← "
                    + "(B6); the CI run times it too"
            case .cold:
                summary =
                    "open \(ColdChildren.count) never-opened subfolders of --path once each, as "
                    + "--cold-children picks them (B3 cold); once per mount; run before revisit"
            case .revisit:
                summary = "open the same subfolders again, timed to their cached rows (B4)"
            case .columnWalk:
                summary =
                    "walk --path in column view with ↓, → and ←; fails on any stall after the "
                    + "launch warm-up (B6, B10)"
            case .splits:
                summary =
                    "W2 in a split window: ↓ in the focused pane of two panes and of a 4-pane "
                    + "grid (B6), and ten panes opening W2 to the focused pane's first rows, "
                    + "\(UIBenchOptions.tenPaneOpens) times (B2, stalls counted); fails if an "
                    + "unfocused pane redraws during ↓; the CI run times it too"
            case .restoredSession:
                summary =
                    "each launch restores a saved session of 3 windows × 2 tabs × 4 panes on W1, "
                    + "one pane on W2, timed to every window on screen and the key window's "
                    + "focused pane showing rows (B1)"
            }
            let path = scenario.needsPath ? " --path <dir>" : ""
            return "  \(scenario.rawValue)\(path)\n      \(summary)"
        }
        return (["scenarios, run with --ui --scenario <name>; each is one launch:"] + lines)
            .joined(separator: "\n")
    }

    /// Checks that a `--path` folder exists, so call it off the main thread.
    static func parse(_ arguments: [String]) throws -> BenchArguments {
        var folder: String?
        var app: String?
        var scenario: UIBenchOptions.Scenario?
        var image: String?
        var w8: Fixture.Workload?
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--help":
                return .help
            case "--scenario":
                let names = UIBenchOptions.Scenario.allCases.map(\.rawValue)
                    .joined(separator: ", ")
                guard let name = remaining.popFirst() else {
                    throw Invalid("--scenario needs a name; the scenarios are \(names)")
                }
                guard let named = UIBenchOptions.Scenario(rawValue: name) else {
                    throw Invalid("unknown scenario \(name); the scenarios are \(names)")
                }
                scenario = named
            case "--print-budget":
                guard let id = remaining.popFirst() else {
                    throw Invalid("--print-budget needs an ID")
                }
                return .printBudget(try Budget.named(id))
            case "--check-idle":
                return .checkIdle
            case "--print-stall-arguments":
                return .printStallArguments
            case "--disk-image-size":
                let run = try parse(Array(remaining))
                if case .diskImageSize = run { throw Invalid("--disk-image-size is given twice") }
                return .diskImageSize(run)
            case "--image":
                image = try existingFolder(remaining.popFirst(), for: argument)
            case "--w8-2gb":
                w8 = .w8CI
            case BenchCase.footprintArgument:
                guard let path = remaining.popFirst() else {
                    throw Invalid("\(BenchCase.footprintArgument) needs a folder")
                }
                return .footprintOfOpening(folder: path)
            case "--cold-children":
                return .coldChildren(
                    folder: try existingFolder(remaining.popFirst(), for: argument))
            case "compare":
                guard let previous = remaining.popFirst(), let current = remaining.popFirst() else {
                    throw Invalid("compare needs a previous report and a current report")
                }
                return .compare(previous: previous, current: current)
            case "compare-ui":
                guard let previous = remaining.popFirst(), let current = remaining.popFirst(),
                    let branch = remaining.popFirst()
                else {
                    throw Invalid(
                        "compare-ui needs a previous history, a UI bench record and a branch")
                }
                return .compareUI(previous: previous, current: current, branch: branch)
            case "--path":
                folder = try existingFolder(remaining.popFirst(), for: argument)
            case "--ui":
                guard let path = remaining.popFirst() else {
                    throw Invalid("--ui needs the app bundle's path")
                }
                app = path
            default:
                throw Invalid("unknown argument \(argument)")
            }
        }
        if w8 != nil, app == nil || scenario != nil {
            throw Invalid("--w8-2gb is for --ui without --scenario, the run that copies W8")
        }
        if let scenario {
            guard app != nil else { throw Invalid("--scenario \(scenario.rawValue) needs --ui") }
            // Never a default folder: these time a share, which only the caller can name.
            if scenario.needsPath, folder == nil {
                throw Invalid(
                    "\(scenario.rawValue) needs --path <dir>, the folder on the share to time")
            }
        }
        if let app {
            return .ui(app: app, folder: folder, scenario: scenario, image: image, w8: w8 ?? .w8)
        }
        return .run(folder: folder, image: image)
    }

    private static func existingFolder(_ path: String?, for argument: String) throws -> String {
        guard let path else { throw Invalid("\(argument) needs a folder") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw Invalid("\(argument) is not an existing folder: \(path)") }
        return path
    }

    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
