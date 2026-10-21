import Base
import Foundation

/// What one invocation of the runner does, parsed from its command line.
enum BenchArguments: Equatable {
    /// Print one budget's number and exit, for scripts that pass it on.
    case printBudget(Budget)
    /// Time every registered case, against `folder` when given.
    case run(folder: String?)
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
    /// when given.
    case ui(app: String, folder: String?)
    /// Print `stallArguments()` on one line, for scripts that launch the app.
    case printStallArguments

    /// The app's launch arguments that start its stall watchdog at B10.
    static func stallArguments() throws -> [String] {
        [StallWatchdog.thresholdArgument, try Budget.named("B10").formattedLimit]
    }

    /// Checks that a `--path` folder exists, so call it off the main thread.
    static func parse(_ arguments: [String]) throws -> BenchArguments {
        var folder: String?
        var app: String?
        var remaining = arguments[...]
        while let argument = remaining.popFirst() {
            switch argument {
            case "--print-budget":
                guard let id = remaining.popFirst() else {
                    throw Invalid("--print-budget needs an ID")
                }
                return .printBudget(try Budget.named(id))
            case "--check-idle":
                return .checkIdle
            case "--print-stall-arguments":
                return .printStallArguments
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
        if let app { return .ui(app: app, folder: folder) }
        return .run(folder: folder)
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
