import Base
import Foundation
import os

/// The space available on each volume, for the windows' status bars, app-wide. A volume's space
/// is read off the main thread on a `BlockingCallThread` the first time it is asked for and
/// again on `refresh`, and kept between reads, so a status bar shows the last value at once. A
/// volume has at most one read in flight: a share that stopped answering holds one thread, and
/// asking again starts nothing until that read returns. A volume unmounted or mounted at a
/// mount point is forgotten there, so a disk mounted where another was is read afresh, even
/// while a read of the old one hangs (docs/decisions/0131-status-bar.md).
@MainActor
public final class FreeSpace {
    /// Reads the bytes available on the volume mounted at a path; nil when the volume doesn't
    /// say. It runs on a `BlockingCallThread`.
    public typealias Read = @Sendable (String) throws -> Int64?

    private let read: Read
    /// The last value read for each volume.
    private var values: [VolumeIdentity: Int64] = [:]
    /// Volumes whose last read failed or said nothing. They aren't read again until `refresh`,
    /// so a volume that can't answer isn't asked on every change of a status bar.
    private var unknown: Set<VolumeIdentity> = []
    /// Volumes with a read in flight, each with the number its read was started under. A read
    /// that lands under another number, or after its volume was forgotten, is dropped.
    private var reading: [VolumeIdentity: Int] = [:]
    /// Counts reads started, numbering them.
    private var readCount = 0
    /// How many reads are in flight, for tests.
    var readsInFlight: Int { reading.count }
    /// How many reads landed after their volume was forgotten and were dropped, for tests.
    private(set) var droppedReads = 0
    /// Volumes `refresh` asked for while a read was in flight, read again once it returns.
    private var readAgain: Set<VolumeIdentity> = []
    private var observers: [Observer] = []
    private let logger = Logger(category: "free-space")

    private struct Observer {
        weak var owner: AnyObject?
        let handler: @MainActor () -> Void
    }

    /// Reads each volume with `availableCapacity(atPath:)`.
    public convenience init() {
        self.init(read: availableCapacity(atPath:))
    }

    /// Reads each volume with `read`, on a `BlockingCallThread`. Tests pass a stub.
    public init(read: @escaping Read) {
        self.read = read
        VolumeEvents.add(self)
    }

    /// The bytes available on `volume` as last read, or nil until a read has returned one. The
    /// first ask starts a read; `observe`'s handlers run when it lands.
    public func available(on volume: VolumeIdentity) -> Int64? {
        if values[volume] == nil, !unknown.contains(volume) {
            start(volume)
        }
        return values[volume]
    }

    /// Reads `volume` again, keeping its last value until the new one lands: for a status bar
    /// that moved onto it from another volume.
    public func refresh(_ volume: VolumeIdentity) {
        unknown.remove(volume)
        if reading[volume] != nil {
            readAgain.insert(volume)
        } else {
            start(volume)
        }
    }

    /// Reads every volume read before again, after a file operation that can change their
    /// space finished.
    public func refresh() {
        for volume in Set(values.keys).union(unknown) {
            refresh(volume)
        }
    }

    /// Runs `handler` after each change of a volume's value, for as long as `owner` exists.
    public func observe(for owner: AnyObject, _ handler: @escaping @MainActor () -> Void) {
        observers.removeAll { $0.owner == nil }
        observers.append(Observer(owner: owner, handler: handler))
    }

    /// The volume at `mountPoint` unmounted: its value goes, and a read of it still in flight
    /// is dropped when it lands. The status bars hear of it.
    func volumeDidUnmount(at mountPoint: String) {
        guard forget(at: mountPoint) else { return }
        notify()
    }

    /// A volume mounted at `mountPoint`, perhaps another disk where one was: what was known of
    /// the one before is forgotten, a read of it still in flight is dropped when it lands, and
    /// each volume known there is read afresh. A volume nothing was known of is read when a bar
    /// first asks, as its panes list again after the mount.
    func volumeDidMount(at mountPoint: String) {
        let known = Set(values.keys).union(unknown).union(reading.keys).filter {
            $0.mountPoint == mountPoint
        }
        guard forget(at: mountPoint) else { return }
        for volume in known {
            start(volume)
        }
        notify()
    }

    /// Forgets every volume at `mountPoint`: values, failures, reads asked again and reads in
    /// flight. Returns whether there was anything to forget.
    @discardableResult
    private func forget(at mountPoint: String) -> Bool {
        let isThere: (VolumeIdentity) -> Bool = { $0.mountPoint == mountPoint }
        let had =
            values.keys.contains(where: isThere) || unknown.contains(where: isThere)
            || reading.keys.contains(where: isThere)
        values = values.filter { !isThere($0.key) }
        unknown = unknown.filter { !isThere($0) }
        readAgain = readAgain.filter { !isThere($0) }
        reading = reading.filter { !isThere($0.key) }
        return had
    }

    private func start(_ volume: VolumeIdentity) {
        guard reading[volume] == nil else { return }
        readCount += 1
        let number = readCount
        reading[volume] = number
        let read = read
        let mountPoint = volume.mountPoint
        Task { [weak self] in
            let result = await BlockingCallThread.run(qos: .utility) {
                Result { try read(mountPoint) }
            }
            self?.land(result, for: volume, number: number)
        }
    }

    private func land(
        _ result: Result<Int64?, any Error>, for volume: VolumeIdentity, number: Int
    ) {
        // A read of a volume since forgotten, by an unmount or a mount there.
        guard reading[volume] == number else {
            droppedReads += 1
            return
        }
        reading[volume] = nil
        let value: Int64?
        switch result {
        case .success(let bytes):
            value = bytes
        case .failure(let error):
            // Private, the logger's default: the mount point and the error name paths.
            logger.error("reading the free space at \(volume.mountPoint) failed: \(error)")
            value = nil
        }
        let old = values[volume]
        values[volume] = value
        if value == nil { unknown.insert(volume) }
        if readAgain.remove(volume) != nil {
            refresh(volume)
        }
        guard value != old else { return }
        notify()
    }

    private func notify() {
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }
}
