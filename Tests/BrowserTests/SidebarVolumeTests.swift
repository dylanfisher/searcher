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

    #expect(!SidebarVolume.isOnlyVolume(first, onItsDiskAmong: mounted))
    #expect(!SidebarVolume.isOnlyVolume(second, onItsDiskAmong: mounted))
    #expect(SidebarVolume.isOnlyVolume(image, onItsDiskAmong: mounted))
    #expect(SidebarVolume.isOnlyVolume(other, onItsDiskAmong: mounted))
    #expect(SidebarVolume.isOnlyVolume(disk1, onItsDiskAmong: mounted))
    #expect(!SidebarVolume.isOnlyVolume(share, onItsDiskAmong: mounted))
    // Once the first is unmounted, the second is the last on disk5.
    #expect(SidebarVolume.isOnlyVolume(second, onItsDiskAmong: [second, image]))
}

@Test func aVolumeSharingItsDiskIsUnmountedAloneAndTheLastOneEjectsTheDisk() {
    let alone = SidebarVolume(mountPoint: "/Volumes/A", name: "A", kind: .local)
    let last = SidebarVolume(mountPoint: "/Volumes/B", name: "B", kind: .local, ejectsDisk: true)

    #expect(alone.unmountOptions == [.withoutUI])
    #expect(last.unmountOptions == [.allPartitionsAndEjectDisk, .withoutUI])
}
