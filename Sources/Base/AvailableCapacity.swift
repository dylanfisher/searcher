import Foundation

/// The bytes available on the volume holding `path`, as Finder's status bar counts them: the
/// larger of the capacity for important use (`volumeAvailableCapacityForImportantUsage`), which
/// adds the space the system can purge to the free space, and the free space itself
/// (`volumeAvailableCapacity`). An SMB share reports 0 for the first and its free space for the
/// second, so the larger is right on both kinds of volume (docs/decisions/0131-status-bar.md).
/// Nil when the volume reports neither. It asks the volume, which can block on a share that
/// stopped answering, so this traps unless it runs on a `BlockingCallThread`.
public func availableCapacity(atPath path: String) throws -> Int64? {
    BlockingCallThread.requireCurrent()
    let values = try URL(fileURLWithPath: path, isDirectory: true).resourceValues(forKeys: [
        .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
    ])
    let important = values.volumeAvailableCapacityForImportantUsage
    let free = values.volumeAvailableCapacity.map(Int64.init)
    switch (important, free) {
    case (let important?, let free?): return max(important, free)
    case (let important?, nil): return important
    case (nil, let free?): return free
    case (nil, nil): return nil
    }
}
