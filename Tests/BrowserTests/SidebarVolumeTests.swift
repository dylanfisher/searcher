import Base
import Foundation
import Testing

@testable import Browser

@Test func findersDefaultLocationsListEjectableVolumesButNotTheStartupOrInternalDisks() {
    let startup = SidebarVolume(
        mountPoint: "/", name: "Macintosh HD", kind: .local, isRootFileSystem: true,
        isInternal: true)
    let internalDisk = SidebarVolume(
        mountPoint: "/Volumes/Spare", name: "Spare", kind: .local, isInternal: true)
    let system = SidebarVolume(
        mountPoint: "/System/Volumes/VM", name: "VM", kind: .local, isBrowsable: false,
        isInternal: true)
    let usb = SidebarVolume(
        mountPoint: "/Volumes/USB", name: "USB", kind: .local, isInternal: false)
    let image = SidebarVolume(mountPoint: "/Volumes/Image", name: "Image", kind: .local)
    let card = SidebarVolume(
        mountPoint: "/Volumes/Card", name: "Card", kind: .local, isInternal: true,
        isRemovable: true, isEjectable: true)
    let share = SidebarVolume(mountPoint: "/Volumes/main", name: "main", kind: .network)

    #expect([startup, internalDisk, system].allSatisfy { !$0.isShown })
    #expect([usb, image, card, share].allSatisfy { $0.isShown && $0.canEject })
    #expect(!startup.canEject && !internalDisk.canEject)
}

@Test func onlyTheLastMountedVolumeOnADiskEjectsTheWholeDisk() {
    let first = VolumeIdentity(device: "/dev/disk5s1", mountPoint: "/Volumes/A", kind: .local)
    let second = VolumeIdentity(device: "/dev/disk5s2", mountPoint: "/Volumes/B", kind: .local)
    let image = VolumeIdentity(device: "/dev/disk7s1", mountPoint: "/Volumes/Image", kind: .local)
    // disk12 isn't disk1: the number is read whole.
    let other = VolumeIdentity(device: "/dev/disk12", mountPoint: "/Volumes/C", kind: .local)
    let share = VolumeIdentity(
        device: "//me@nas.invalid/main", mountPoint: "/Volumes/main", kind: .network)
    let disk1 = VolumeIdentity(device: "/dev/disk1s1s1", mountPoint: "/Volumes/D", kind: .local)
    let mounted = [first, second, image, other, share, disk1]

    // Each whole disk is its own physical disk here.
    let isOnly = { (volume: VolumeIdentity, mounted: [VolumeIdentity]) in
        SidebarVolume.isOnlyVolume(volume, onItsDiskAmong: mounted) { $0 }
    }

    #expect(!isOnly(first, mounted))
    #expect(!isOnly(second, mounted))
    #expect(isOnly(image, mounted))
    #expect(isOnly(other, mounted))
    #expect(isOnly(disk1, mounted))
    #expect(!isOnly(share, mounted))
    // Once the first is unmounted, the second is the last on disk5.
    #expect(isOnly(second, [second, image]))
}

@Test func anAPFSVolumeBesideAPartitionOnItsPhysicalDiskDoesNotEjectTheDisk() {
    // disk6 is the synthesized disk of an APFS container whose physical store is disk4s1; an
    // HFS partition, disk4s2, sits beside it on disk4.
    let apfs = VolumeIdentity(device: "/dev/disk6s1", mountPoint: "/Volumes/APFS", kind: .local)
    let hfs = VolumeIdentity(device: "/dev/disk4s2", mountPoint: "/Volumes/HFS", kind: .local)
    let physical = { (disk: String) in disk == "disk6" ? "disk4" : disk }

    #expect(!SidebarVolume.isOnlyVolume(apfs, onItsDiskAmong: [apfs, hfs], physicalDisk: physical))
    #expect(!SidebarVolume.isOnlyVolume(hfs, onItsDiskAmong: [apfs, hfs], physicalDisk: physical))
    #expect(SidebarVolume.isOnlyVolume(apfs, onItsDiskAmong: [apfs], physicalDisk: physical))
}

@Test func theStartupDisksAPFSContainerIsOnAnotherPhysicalDisk() async throws {
    // Reads the I/O Registry only; nothing is mounted or ejected. The startup disk is an APFS
    // container's synthesized disk on every Mac this app runs on.
    let (disk, physical) = try await BlockingCallThread.run {
        () throws(ListingError) -> (String?, String?) in
        let root = try VolumeIdentity(path: "/")
        let disk = SidebarVolume.wholeDisk(of: root.device)
        return (disk, disk.map(SidebarVolume.physicalDisk(of:)))
    }

    let whole = try #require(disk)
    #expect(physical != nil && physical != whole)
    #expect(physical?.hasPrefix("disk") == true)
}

@Test func aVolumeSharingItsDiskIsUnmountedAloneAndTheLastOneEjectsTheDisk() {
    let alone = SidebarVolume(mountPoint: "/Volumes/A", name: "A", kind: .local)
    let last = SidebarVolume(mountPoint: "/Volumes/B", name: "B", kind: .local, ejectsDisk: true)

    #expect(alone.unmountOptions == [.withoutUI])
    #expect(last.unmountOptions == [.allPartitionsAndEjectDisk, .withoutUI])
}

@Test func hiddenVolumesOnADiskGoWithItWhenItsLastBrowsableVolumeEjects() {
    let data = VolumeIdentity(device: "/dev/disk8s1", mountPoint: "/Volumes/Mac", kind: .local)
    let preboot = VolumeIdentity(
        device: "/dev/disk8s2", mountPoint: "/Volumes/Preboot", kind: .local, isBrowsable: false)
    let hiddenElsewhere = VolumeIdentity(
        device: "/dev/disk9s1", mountPoint: "/Volumes/VM", kind: .local, isBrowsable: false)
    let mounted = [data, preboot, hiddenElsewhere]

    #expect(SidebarVolume.isOnlyVolume(data, onItsDiskAmong: mounted) { $0 })
    // A second browsable volume still keeps the disk.
    let second = VolumeIdentity(device: "/dev/disk8s3", mountPoint: "/Volumes/Two", kind: .local)
    #expect(!SidebarVolume.isOnlyVolume(data, onItsDiskAmong: mounted + [second]) { $0 })
}
