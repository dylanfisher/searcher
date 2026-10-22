import Base
import Foundation

/// Times listing `count` different subfolders of one folder, each once, so every sample is a
/// folder the share has not served to this Mac before (B3 cold). `./scripts/bench
/// --cold-children <dir>` runs it.
enum ColdChildren {
    static let count = 20

    /// Lists the first `count` subfolders of `folder` in name order, one `list` call each, and
    /// returns each call's time in milliseconds. Call it off the main thread.
    static func time(in folder: String, lister: any Lister) throws -> Samples {
        var children: [String] = []
        try lister.list(folder) { batch in
            children += batch.filter { $0.type == .directory }.map(\.name)
        }
        guard children.count >= count else {
            throw TooFewChildren(folder: folder, found: children.count)
        }
        children.sort()
        let clock = ContinuousClock()
        var samples: [Double] = []
        for child in children.prefix(count) {
            let elapsed = try clock.measure {
                try lister.list(folder + "/" + child) { _ in }
            }
            samples.append(BenchCase.milliseconds(elapsed))
        }
        return Samples(samples)
    }

    struct TooFewChildren: Error, CustomStringConvertible {
        let folder: String
        let found: Int
        var description: String {
            "--cold-children needs \(ColdChildren.count) subfolders in \(folder); it has \(found)"
        }
    }
}
