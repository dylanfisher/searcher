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

    /// Checks that a `--path` folder exists, so call it off the main thread.
    static func parse(_ arguments: [String]) throws -> BenchArguments {
        var folder: String?
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
            case BenchCase.footprintArgument:
                guard let path = remaining.popFirst() else {
                    throw Invalid("\(BenchCase.footprintArgument) needs a folder")
                }
                return .footprintOfOpening(folder: path)
            case "--path":
                guard let path = remaining.popFirst() else {
                    throw Invalid("--path needs a folder")
                }
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                    isDirectory.boolValue
                else { throw Invalid("--path is not an existing folder: \(path)") }
                folder = path
            default:
                throw Invalid("unknown argument \(argument)")
            }
        }
        return .run(folder: folder)
    }

    struct Invalid: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
