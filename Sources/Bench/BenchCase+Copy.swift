import Base
import Foundation

extension BenchCase {
    /// Runs of the copy case. Each writes 1 GB to the image; ten keep the case near 15 s at S7's
    /// rate.
    static let copyRuns = 10

    /// One 1 GB file copied through `FileCopier` from the boot volume to the disk image mounted at
    /// `image`, which scripts/bench attaches: across volumes, so the bytes are copied, not cloned.
    /// Each run is timed from the call to its return and judged in MB/s against S7. Outside the
    /// timed region, so every run starts alike: one untimed copy first warms the source into the
    /// page cache, as it was in S7, and after each run the copy is removed and the image flushed,
    /// so the last run's dirty pages and freed space don't compete with the next write.
    static func copy(to image: String) -> BenchCase {
        let source = Fixture(.copySource).path.appending(path: Fixture.copySourceFile).path
        return BenchCase(
            name: "copy 1 GB to a disk image through FileCopier", budget: nil, floor: .s7,
            unit: .milliseconds, runs: copyRuns,
            warmUp: { _ in _ = try await timeCopy(source, into: image) },
            run: { _ in try await timeCopy(source, into: image) }
        )
    }

    /// Copies `source` into `folder` under its own name and returns the milliseconds the copy
    /// took, then removes the copy and flushes `folder`'s volume, untimed.
    static func timeCopy(_ source: String, into folder: String) async throws -> Double {
        let destination = folder + "/" + (source as NSString).lastPathComponent
        return try await BlockingCallThread.run { () throws -> Double in
            let start = ContinuousClock.now
            _ = try FileCopier().copy(source, to: destination)
            let elapsed = milliseconds(.now - start)
            try FileManager.default.removeItem(atPath: destination)
            try flush(folder)
            return elapsed
        }
    }

    /// Writes everything buffered for `folder`'s volume to the disk.
    static func flush(_ folder: String) throws {
        let descriptor = open(folder, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
