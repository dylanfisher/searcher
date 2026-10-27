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
        let clock = ContinuousClock()
        var samples: [Double] = []
        for child in try children(of: folder, lister: lister) {
            let elapsed = try clock.measure {
                try lister.list(child) { _ in }
            }
            samples.append(BenchCase.milliseconds(elapsed))
        }
        return Samples(samples)
    }

    /// The paths of the first `count` subfolders of `folder` in name order, which `time` lists
    /// and the UI bench's `cold` and `revisit` scenarios open. Lists `folder` alone, so the
    /// subfolders stay unopened. Call it off the main thread.
    static func children(of folder: String, lister: any Lister) throws -> [String] {
        var children: [String] = []
        try lister.list(folder) { batch in
            children += batch.filter { $0.type == .directory }.map(\.name)
        }
        guard children.count >= count else {
            throw TooFewChildren(folder: folder, found: children.count)
        }
        return children.sorted().prefix(count).map { join(folder, $0) }
    }

    struct TooFewChildren: Error, CustomStringConvertible {
        let folder: String
        let found: Int
        var description: String {
            "--cold-children needs \(ColdChildren.count) subfolders in \(folder); it has \(found)"
        }
    }
}
