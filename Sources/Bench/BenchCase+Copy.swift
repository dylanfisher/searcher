import Base
import Foundation

extension BenchCase {
    /// Runs of the copy case. Each writes 1 GB to the image; ten keep the case near 15 s at S7's
    /// rate.
    static let copyRuns = 10

    /// One 1 GB file copied through `FileCopier` from the boot volume to the disk image mounted at
    /// `image`, which scripts/bench attaches: across volumes, so the bytes are copied, not cloned.
    /// Each run is timed from the call to its return and judged in MB/s against S7. The copy is
    /// removed after each run, untimed. The source is read from the page cache after the first
    /// run, as it was in S7.
    static func copy(to image: String) -> BenchCase {
        BenchCase(
            name: "copy 1 GB to a disk image through FileCopier", budget: nil, floor: .s7,
            unit: .milliseconds, runs: copyRuns
        ) { _ in
            try await timeCopy(
                Fixture(.copySource).path.appending(path: Fixture.copySourceFile).path, into: image)
        }
    }

    /// Copies `source` into `folder` under its own name and returns the milliseconds the copy
    /// took, then removes the copy.
    static func timeCopy(_ source: String, into folder: String) async throws -> Double {
        let destination = folder + "/" + (source as NSString).lastPathComponent
        return try await BlockingCallThread.run { () throws -> Double in
            let start = ContinuousClock.now
            _ = try FileCopier().copy(source, to: destination)
            let elapsed = milliseconds(.now - start)
            try FileManager.default.removeItem(atPath: destination)
            return elapsed
        }
    }
}
