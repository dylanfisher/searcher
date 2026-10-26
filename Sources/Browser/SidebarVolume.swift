import Base
import Foundation

/// A mounted volume as the sidebar's Locations sees it: where it is mounted, its name, and what
/// says whether Finder's default sidebar lists it and offers to eject it
/// (docs/decisions/0108-sidebar-locations.md).
public struct SidebarVolume: Equatable, Sendable {
    public let mountPoint: String
    /// The volume's name as Finder shows it: its localized name for a volume on this machine,
    /// the mount point's last component for a share, which isn't asked.
    public let name: String
    public let kind: VolumeKind
    /// Whether the volume is mounted without `MNT_DONTBROWSE`, as Finder lists volumes.
    public let isBrowsable: Bool
    /// Whether it is the startup disk, mounted at `/`.
    public let isRootFileSystem: Bool
    /// Whether it is on an internal bus; nil when the system doesn't say, as for a disk image.
    public let isInternal: Bool?
    public let isRemovable: Bool
    public let isEjectable: Bool

    public init(
        mountPoint: String, name: String, kind: VolumeKind, isBrowsable: Bool = true,
        isRootFileSystem: Bool = false, isInternal: Bool? = nil, isRemovable: Bool = false,
        isEjectable: Bool = false
    ) {
        self.mountPoint = mountPoint
        self.name = name
        self.kind = kind
        self.isBrowsable = isBrowsable
        self.isRootFileSystem = isRootFileSystem
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
    }

    /// Whether the volume can be ejected or unmounted from the sidebar, as Finder's eject button
    /// shows: a share, a removable or ejectable disk, or any disk not on an internal bus, which
    /// takes in disk images.
    public var canEject: Bool {
        kind == .network || isRemovable || isEjectable || isInternal != true
    }

    /// Whether Finder's default sidebar lists the volume under Locations: External disks, CDs,
    /// DVDs and iOS devices, and Connected servers are on, and Hard disks, which takes in the
    /// startup disk, is off. So it lists what can be ejected, and neither the startup disk nor
    /// a volume Finder doesn't show at all.
    public var isShown: Bool {
        isBrowsable && !isRootFileSystem && canEject
    }

    /// Every mounted volume, in the kernel's mount table order. A volume on this machine is
    /// asked its name and how it is attached; a share isn't asked anything, since one that has
    /// stopped answering would hold the read. Traps unless it runs on a `BlockingCallThread`.
    public static func mounted() -> [SidebarVolume] {
        BlockingCallThread.requireCurrent()
        return VolumeIdentity.mounted().compactMap { volume in
            let name = VolumeIdentity.name(mountedAt: volume.mountPoint)
            guard volume.kind == .local, volume.isBrowsable else {
                return SidebarVolume(
                    mountPoint: volume.mountPoint, name: name, kind: volume.kind,
                    isBrowsable: volume.isBrowsable)
            }
            let url = URL(fileURLWithPath: volume.mountPoint, isDirectory: true)
            let keys: Set<URLResourceKey> = [
                .volumeLocalizedNameKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey,
                .volumeIsRemovableKey, .volumeIsEjectableKey,
            ]
            // A volume unmounted since the table was read can't be asked; the unmount's own
            // event reads the table again.
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return SidebarVolume(
                mountPoint: volume.mountPoint, name: values.volumeLocalizedName ?? name,
                kind: volume.kind, isBrowsable: true,
                isRootFileSystem: values.volumeIsRootFileSystem ?? (volume.mountPoint == "/"),
                isInternal: values.volumeIsInternal,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false)
        }
    }

    /// Why an eject failed, as the system says it.
    public struct EjectFailure: Error, Equatable {
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }

    /// Unmounts the volume and, for a disk on this machine, ejects its disk with every volume
    /// on it, as Finder's eject button does; a disk image is detached. It asks with no UI of
    /// the system's, and waits for the answer, so it traps unless it runs on a
    /// `BlockingCallThread`.
    public static func eject(_ volume: SidebarVolume) throws(EjectFailure) {
        BlockingCallThread.requireCurrent()
        let options: FileManager.UnmountOptions =
            volume.kind == .local ? [.allPartitionsAndEjectDisk, .withoutUI] : [.withoutUI]
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        FileManager.default.unmountVolume(
            at: URL(fileURLWithPath: volume.mountPoint, isDirectory: true), options: options
        ) { error in
            answer.failure = error.map { EjectFailure(reason: $0.localizedDescription) }
            done.signal()
        }
        done.wait()
        if let failure = answer.failure { throw failure }
    }

    /// What the unmount's completion handler found, set before it signals and read by the
    /// waiting thread after; the semaphore orders the two.
    private final class Answer: @unchecked Sendable {
        var failure: EjectFailure?
    }
}
