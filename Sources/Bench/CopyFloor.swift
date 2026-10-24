/// The slowest copy rate a copy case may show, taken from a spike rather than the budget table:
/// `Budget` holds the table's numbers alone, in ms and MB. A copy case's samples are the
/// milliseconds each run took to copy `bytes`. S7's rate is a median of 5 runs and runs to an image
/// swing about 2x, so the case's median is the rate judged, like with like; its p95 is reported.
struct CopyFloor: Sendable, Equatable, Codable {
    /// Spike S7's `copyfile` with `COPYFILE_ALL | COPYFILE_CLONE`, the flags `FileCopier` uses,
    /// copying a 2 GiB file from the boot volume to an attached APFS image: 1197 MB/s in its
    /// 3-run pass and 792 in its 5-run pass (docs/decisions/0058-copy-engine.md). The lower one.
    static let s7 = CopyFloor(id: "S7", megabytesPerSecond: 792, bytes: 1_000_000_000)

    let id: String
    /// MB is 10^6 bytes, as in S7.
    let megabytesPerSecond: Int
    /// What each run copies.
    let bytes: Int64

    /// The rate of a run that copied `bytes` in `milliseconds`, in MB/s.
    func rate(milliseconds: Double) -> Double {
        Double(bytes) / 1e6 / (milliseconds / 1000)
    }

    /// Whether a rate under the floor fails the run: everywhere but CI, whose hosted runners copy
    /// to virtualised disks at a rate no run has measured yet. There it is printed, reported only.
    static func isEnforced(environment: [String: String]) -> Bool {
        environment["CI"] == nil
    }

    /// Whether a run that took `milliseconds` was slower than the floor.
    func isMissed(byMilliseconds milliseconds: Double) -> Bool {
        rate(milliseconds: milliseconds) < Double(megabytesPerSecond)
    }
}
