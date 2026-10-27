import Foundation

/// A load's waits for a batch: reported slow after `LoadTimeouts.slow` and given up after
/// `LoadTimeouts.giveUp`, each at most once, counted from the request and from each batch. A
/// report waits for the volume names, which a load's thread reads, so no timer reads the file
/// system on the concurrency pool.
final class LoadStall: @unchecked Sendable {
    enum Kind {
        case slow
        case giveUp
    }

    /// The root volume's name, for the path bar, and the name of the volume holding the folder.
    struct VolumeNames {
        let root: String
        let folder: String
    }

    // `lock` guards everything below.
    private let lock = NSLock()
    private var timers: [Task<Void, Never>] = []
    private var generation = 0
    private var reported: Set<Kind> = []
    private var isFinished = false
    private var volumeNames: VolumeNames?
    /// Reports due before the volume names were read.
    private var waitingReports: [(VolumeNames) -> Void] = []

    /// Cancels the running timers and starts the ones `makeTimers` returns for a new generation,
    /// unless the load has ended.
    func restart(_ makeTimers: (Int) -> [Task<Void, Never>]) {
        lock.withLock {
            guard !isFinished else { return }
            for timer in timers { timer.cancel() }
            generation += 1
            timers = makeTimers(generation)
        }
    }

    /// Runs `report` with the volume names once per kind, if the timers of `generation` are
    /// still the current ones and the load hasn't ended or been cancelled. Before the names are
    /// read, the report waits for them.
    func report(_ kind: Kind, generation: Int, _ report: @escaping (VolumeNames) -> Void) {
        lock.withLock {
            guard !isFinished, generation == self.generation, !reported.contains(kind) else {
                return
            }
            reported.insert(kind)
            if let volumeNames {
                report(volumeNames)
            } else {
                waitingReports.append(report)
            }
        }
    }

    /// Takes the volume names, read on a load's thread, and runs the reports that waited for
    /// them.
    func setVolumeNames(root: String, folder: String) {
        lock.withLock {
            let names = VolumeNames(root: root, folder: folder)
            volumeNames = names
            guard !isFinished else { return }
            for report in waitingReports { report(names) }
            waitingReports = []
        }
    }

    /// Stops the timers for good and runs `last`, the load's last hand-off, under the lock. A
    /// cancelled load finishes with nothing to hand.
    func finish(_ last: () -> Void) {
        lock.withLock {
            isFinished = true
            for timer in timers { timer.cancel() }
            timers = []
            waitingReports = []
            last()
        }
    }
}
