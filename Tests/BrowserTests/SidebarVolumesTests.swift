import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser

/// A mount point no other test uses, since every list hears every volume event.
private func uniqueMountPoint() -> String {
    "/sidebar-volumes-\(UUID().uuidString)"
}

private func disk(_ mountPoint: String) -> SidebarVolume {
    SidebarVolume(
        mountPoint: mountPoint, name: Location(path: mountPoint).name, kind: .local,
        isInternal: false)
}

@MainActor @Test func theListShowsTheVolumesFinderListsReadOffTheMainThread() async {
    let usb = disk("/Volumes/USB")
    let stub = StubSidebarVolumes([
        SidebarVolume(
            mountPoint: "/", name: "Macintosh HD", kind: .local, isRootFileSystem: true,
            isInternal: true),
        usb,
    ])

    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }

    #expect(volumes.volumes == [usb])
    #expect(stub.readThreads.allSatisfy { $0 })
}

@MainActor @Test func mountAndUnmountEventsReadTheVolumesAgainAndTellTheObservers() async {
    let stub = StubSidebarVolumes()
    let volumes = stub.list()
    var changes = 0
    volumes.observe(for: stub) { changes += 1 }
    let mountPoint = uniqueMountPoint()
    await settle { stub.readThreads.count == 1 }

    stub.set([disk(mountPoint)])
    VolumeEvents.didMount(at: mountPoint)
    await settle { volumes.volumes.count == 1 }
    #expect(changes == 1)

    stub.set([])
    VolumeEvents.didUnmount(at: mountPoint)
    await settle { volumes.volumes.isEmpty }
    #expect(changes == 2)
}

@MainActor @Test func ejectStopsTheAppsLoadsOnTheVolumeThenEjectsOffTheMainThread() async {
    let mountPoint = uniqueMountPoint()
    let folder = mountPoint + "/music"
    let lister = GatedLister([folder: .blockForever])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: folder), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    #expect(await lister.waitForCall(folder))
    let load = pane.load
    let stub = StubSidebarVolumes([disk(mountPoint)])
    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }

    await #expect(throws: Never.self) { try await volumes.eject(disk(mountPoint)) }

    #expect(load?.isCancelled == true)
    #expect(pane.monitorGeneration == 0)
    #expect(stub.ejects.map(\.mountPoint) == [mountPoint])
    #expect(stub.ejects.map(\.onBlockingThread) == [true])
    // `VolumeEvents` holds panes weakly.
    withExtendedLifetime(pane) {}
}

@MainActor @Test func aFailedEjectThrowsTheSystemsReason() async {
    let mountPoint = uniqueMountPoint()
    let stub = StubSidebarVolumes([disk(mountPoint)])
    stub.fail(with: "The volume is in use.")
    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }

    await #expect(throws: SidebarVolume.EjectFailure(reason: "The volume is in use.")) {
        try await volumes.eject(disk(mountPoint))
    }
}

@MainActor @Test func aRefusedEjectListsThePanesOnTheVolumeAgainAndWatchesThemAgain() async {
    let mountPoint = uniqueMountPoint()
    let folder = mountPoint + "/music"
    let lister = GatedLister([folder: .blockForever])
    lister.releaseAll()
    let pane = Pane(
        location: Location(path: folder), service: ListingService(lister: lister),
        systemActions: StubSystemActions(), settings: untouchedSettings())
    #expect(await lister.waitForCalls(1))
    let monitor = StubMonitor()
    pane.monitor = monitor
    let generation = pane.monitorGeneration
    let stub = StubSidebarVolumes([disk(mountPoint)])
    stub.fail(with: "The volume is in use.")
    let volumes = stub.list()

    await #expect(throws: SidebarVolume.EjectFailure.self) {
        try await volumes.eject(disk(mountPoint))
    }

    #expect(monitor.stopCount == 1)
    #expect(pane.monitorGeneration == generation + 1)
    #expect(await lister.waitForCalls(2))
    #expect(!pane.state.isOffline)
}

@MainActor @Test func aSecondEjectOfAVolumeBeingEjectedIsIgnored() async throws {
    let mountPoint = uniqueMountPoint()
    let stub = StubSidebarVolumes([disk(mountPoint)])
    stub.holdEjects()
    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }
    var changes = 0
    volumes.observe(for: stub) { changes += 1 }
    let first = Task { try await volumes.eject(disk(mountPoint)) }
    await settle { stub.ejects.count == 1 }
    #expect(volumes.ejecting == [mountPoint])

    try await volumes.eject(disk(mountPoint))

    #expect(stub.ejects.count == 1)
    stub.releaseEjects()
    try await first.value
    #expect(volumes.ejecting.isEmpty)
    #expect(changes == 2)
}
