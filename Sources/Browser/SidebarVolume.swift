import Base
import Foundation
import IOKit

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
    /// Whether ejecting it ejects its whole disk: it is on this machine and no other volume is
    /// mounted from that physical disk (`isOnlyVolume(_:onItsDiskAmong:physicalDisk:)`).
    public let ejectsDisk: Bool

    public init(
        mountPoint: String, name: String, kind: VolumeKind, isBrowsable: Bool = true,
        isRootFileSystem: Bool = false, isInternal: Bool? = nil, isRemovable: Bool = false,
        isEjectable: Bool = false, ejectsDisk: Bool = false
    ) {
        self.mountPoint = mountPoint
        self.name = name
        self.kind = kind
        self.isBrowsable = isBrowsable
        self.isRootFileSystem = isRootFileSystem
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.ejectsDisk = ejectsDisk
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
        let mounted = VolumeIdentity.mounted()
        var physicalDisks: [String: String] = [:]
        for disk in Set(mounted.compactMap { wholeDisk(of: $0.device) }) {
            physicalDisks[disk] = physicalDisk(of: disk)
        }
        let physicalDisk = { (disk: String) in physicalDisks[disk] ?? disk }
        return mounted.compactMap { volume in
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
            // A volume that doesn't answer was unmounted after the table was read: the table and
            // the unmount race. It is left out rather than listed with made-up details, and the
            // unmount's own event reads the table again without it.
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return SidebarVolume(
                mountPoint: volume.mountPoint, name: values.volumeLocalizedName ?? name,
                kind: volume.kind, isBrowsable: true,
                isRootFileSystem: values.volumeIsRootFileSystem ?? (volume.mountPoint == "/"),
                isInternal: values.volumeIsInternal,
                isRemovable: values.volumeIsRemovable ?? false,
                isEjectable: values.volumeIsEjectable ?? false,
                ejectsDisk: isOnlyVolume(
                    volume, onItsDiskAmong: mounted, physicalDisk: physicalDisk))
        }
    }

    /// Whether `volume` is on this machine and the only one of `mounted`, every mounted volume
    /// browsable or not, on its physical disk. A volume's whole disk comes from its device name
    /// (`/dev/disk5s2` is on `disk5`), and `physicalDisk` gives the physical disk a whole disk
    /// is on: an APFS container's synthesized disk is on the disk of its physical store, so a
    /// partition of another format beside the container counts.
    static func isOnlyVolume(
        _ volume: VolumeIdentity, onItsDiskAmong mounted: [VolumeIdentity],
        physicalDisk: (String) -> String
    ) -> Bool {
        guard volume.kind == .local, let disk = wholeDisk(of: volume.device).map(physicalDisk)
        else { return false }
        return mounted.filter { wholeDisk(of: $0.device).map(physicalDisk) == disk }.count == 1
    }

    /// The physical disk the whole disk `disk`, such as `disk6`, is on, from the I/O Registry:
    /// the whole disk of the first media above it with a BSD name, which for an APFS container's
    /// synthesized disk is its physical store (`disk0s2`, so `disk0`). A disk with no media
    /// above it is its own. One the registry doesn't list, as one just detached, is taken as
    /// its own too: it can no longer share anything. Traps unless it runs on a
    /// `BlockingCallThread`.
    static func physicalDisk(of disk: String) -> String {
        BlockingCallThread.requireCurrent()
        // IOServiceGetMatchingService consumes the matching dictionary.
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, disk))
        guard service != IO_OBJECT_NULL else { return disk }
        var entry = service
        while true {
            var parent: io_registry_entry_t = IO_OBJECT_NULL
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS else { return disk }
            if IOObjectConformsTo(parent, "IOMedia") != 0,
                let name = IORegistryEntryCreateCFProperty(
                    parent, "BSD Name" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String
            {
                IOObjectRelease(parent)
                return wholeDisk(of: "/dev/" + name) ?? name
            }
            entry = parent
        }
    }

    /// The whole disk a device such as `/dev/disk5s2` is a slice of, `disk5`; nil for a device
    /// that isn't a disk.
    static func wholeDisk(of device: String) -> String? {
        let prefix = "/dev/disk"
        guard device.hasPrefix(prefix) else { return nil }
        let number = device.dropFirst(prefix.count).prefix { $0.isASCII && $0.isNumber }
        return number.isEmpty ? nil : "disk\(number)"
    }

    /// How the volume is unmounted: with its whole disk ejected when it is the disk's only
    /// mounted volume, which detaches a disk image, as Finder's eject button does; on its own
    /// otherwise, leaving the disk's other volumes mounted, where Finder would first ask about
    /// them. The system shows no UI of its own either way.
    public var unmountOptions: FileManager.UnmountOptions {
        ejectsDisk ? [.allPartitionsAndEjectDisk, .withoutUI] : [.withoutUI]
    }

    /// Why an eject failed, as the system says it.
    public struct EjectFailure: Error, Equatable {
        public let reason: String

        public init(reason: String) {
            self.reason = reason
        }
    }

    /// Unmounts the volume as `unmountOptions` says, and waits for the answer, so it traps
    /// unless it runs on a `BlockingCallThread`.
    public static func eject(_ volume: SidebarVolume) throws(EjectFailure) {
        BlockingCallThread.requireCurrent()
        let done = DispatchSemaphore(value: 0)
        let answer = Answer()
        FileManager.default.unmountVolume(
            at: URL(fileURLWithPath: volume.mountPoint, isDirectory: true),
            options: volume.unmountOptions
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
