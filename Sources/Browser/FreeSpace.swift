import Base
import Foundation
import os

/// The space available on each volume, for the windows' status bars, app-wide. A volume's space
/// is read off the main thread on a `BlockingCallThread` the first time it is asked for and
/// again on `refresh`, and kept between reads, so a status bar shows the last value at once. A
/// volume has at most one read in flight: a share that stopped answering holds one thread, and
/// asking again starts nothing until that read returns (docs/decisions/0131-status-bar.md).
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
    /// Volumes with a read in flight.
    private var reading: Set<VolumeIdentity> = []
    /// How many reads are in flight, for tests.
    var readsInFlight: Int { reading.count }
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
        if reading.contains(volume) {
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

    private func start(_ volume: VolumeIdentity) {
        guard reading.insert(volume).inserted else { return }
        let read = read
        let mountPoint = volume.mountPoint
        Task { [weak self] in
            let result = await BlockingCallThread.run(qos: .utility) {
                Result { try read(mountPoint) }
            }
            self?.land(result, for: volume)
        }
    }

    private func land(_ result: Result<Int64?, any Error>, for volume: VolumeIdentity) {
        reading.remove(volume)
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
        observers.removeAll { $0.owner == nil }
        for observer in observers {
            observer.handler()
        }
    }
}
