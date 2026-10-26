import Base
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
