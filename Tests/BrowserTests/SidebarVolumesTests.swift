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
    await settle { stub.readThreads.count >= 1 }

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
    #expect(changes == 2)
}

@MainActor @Test func anEjectedVolumeStaysEjectingUntilAReadWithoutItLands() async throws {
    let mountPoint = uniqueMountPoint()
    let stub = StubSidebarVolumes([disk(mountPoint)])
    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }

    try await volumes.eject(disk(mountPoint))
    #expect(volumes.ejecting == [mountPoint])
    try await volumes.eject(disk(mountPoint))
    #expect(stub.ejects.count == 1)

    // A read that still lists it, as one started before the unmount, keeps it.
    let landed = volumes.readsLanded
    VolumeEvents.didMount(at: uniqueMountPoint())
    await settle { volumes.readsLanded > landed }
    #expect(volumes.ejecting == [mountPoint])

    stub.set([])
    VolumeEvents.didUnmount(at: mountPoint)
    await settle { volumes.volumes.isEmpty }
    #expect(volumes.ejecting.isEmpty)
}

@MainActor @Test func aVolumeMountedAgainAtAnEjectedOnesMountPointCanBeEjected() async throws {
    let mountPoint = uniqueMountPoint()
    let stub = StubSidebarVolumes([disk(mountPoint)])
    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }
    try await volumes.eject(disk(mountPoint))
    #expect(volumes.ejecting == [mountPoint])

    // Its unmount's read was overtaken by the mount's, which lists the new volume.
    VolumeEvents.didMount(at: mountPoint)

    #expect(volumes.ejecting.isEmpty)
}

@MainActor @Test func aRefusedEjectIsNoLongerEjecting() async {
    let mountPoint = uniqueMountPoint()
    let stub = StubSidebarVolumes([disk(mountPoint)])
    stub.fail(with: "The volume is in use.")
    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }

    await #expect(throws: SidebarVolume.EjectFailure.self) {
        try await volumes.eject(disk(mountPoint))
    }

    #expect(volumes.ejecting.isEmpty)
}

/// Holds the first read until `releaseFirst()`, which then lists `first`; every later read lists
/// `later` at once. Counts the reads started, and whether the first has returned.
private final class FirstReadGate: @unchecked Sendable {
    // `lock` guards `reads` and `returnedFirst`.
    private let lock = NSLock()
    private var reads = 0
    private var returnedFirst = false
    private let gate = DispatchSemaphore(value: 0)
    let first: [SidebarVolume]
    let later: [SidebarVolume]

    init(first: [SidebarVolume], later: [SidebarVolume]) {
        self.first = first
        self.later = later
    }

    func read() -> [SidebarVolume] {
        let isFirst = lock.withLock {
            reads += 1
            return reads == 1
        }
        guard isFirst else { return later }
        gate.wait()
        lock.withLock { returnedFirst = true }
        return first
    }

    var readsStarted: Int { lock.withLock { reads } }
    var firstHasReturned: Bool { lock.withLock { returnedFirst } }

    func releaseFirst() {
        gate.signal()
    }
}

@MainActor @Test func anOlderReadThatLandsAfterANewerOneIsDropped() async {
    let mountPoint = uniqueMountPoint()
    let old = disk(mountPoint + "-old")
    let new = disk(mountPoint + "-new")
    let gate = FirstReadGate(first: [old], later: [new])
    let volumes = SidebarVolumes(read: gate.read, eject: { _ in })
    // The read held started before the mount event's, so it is the older one.
    await settle { gate.readsStarted >= 1 }

    VolumeEvents.didMount(at: mountPoint)
    await settle { volumes.volumes == [new] }
    gate.releaseFirst()
    await settle { gate.firstHasReturned && volumes.readsLanded == gate.readsStarted }

    #expect(volumes.volumes == [new])
}

// MARK: Servers

/// A share of `server` mounted at `mountPoint`.
private func share(_ mountPoint: String, of server: Server?) -> SidebarVolume {
    SidebarVolume(
        mountPoint: mountPoint, name: Location(path: mountPoint).name, kind: .network,
        server: server)
}

@MainActor @Test func aServersSharesAreOneRowWhereItsFirstShareIs() async throws {
    let hal = testServer
    let other = try #require(Server(host: "nas.local"))
    let usb = disk("/Volumes/USB")
    let main = share("/Volumes/main", of: hal)
    let music = share("/Volumes/music", of: Server(host: "hal9000._SMB._tcp.local"))
    let backup = share("/Volumes/backup", of: other)
    let loose = share("/Users/u/mnt/photos", of: nil)
    let stub = StubSidebarVolumes([main, usb, backup, music, loose])

    let volumes = stub.list()
    await settle { !volumes.volumes.isEmpty }

    #expect(
        volumes.rows == [
            .server(hal, shares: [main, music]), .volume(usb), .server(other, shares: [backup]),
            .volume(loose),
        ])
    #expect(volumes.volumes == [main, usb, backup, music, loose])
}

@MainActor @Test func ejectingAServerStopsLoadsOnEachShareAndEjectsThemAllAtOnce() async throws {
    let hal = testServer
    let main = share(uniqueMountPoint(), of: hal)
    let music = share(uniqueMountPoint(), of: hal)
    let folders = [main.mountPoint + "/a", music.mountPoint + "/b"]
    let lister = GatedLister(Dictionary(uniqueKeysWithValues: folders.map { ($0, .blockForever) }))
    lister.releaseAll()
    let panes = folders.map { folder in
        Pane(
            location: Location(path: folder), service: ListingService(lister: lister),
            systemActions: StubSystemActions(), settings: untouchedSettings())
    }
    #expect(await lister.waitForCalls(2))
    let loads = panes.map(\.load)
    let stub = StubSidebarVolumes([main, music])
    stub.holdEjects()
    let volumes = stub.list()
    await settle { volumes.volumes.count == 2 }

    let eject = Task { try await volumes.ejectServer(hal) }
    // Both run before either answers.
    await settle { stub.ejects.count == 2 }
    #expect(volumes.ejecting == [main.mountPoint, music.mountPoint])
    stub.releaseEjects()
    try await eject.value

    #expect(loads.allSatisfy { $0?.isCancelled == true })
    #expect(Set(stub.ejects.map(\.mountPoint)) == [main.mountPoint, music.mountPoint])
    #expect(stub.ejects.map(\.onBlockingThread) == [true, true])
    withExtendedLifetime(panes) {}
}

@MainActor @Test func aServersRefusedSharesAreReportedTogetherWithTheirReasons() async throws {
    let hal = testServer
    let main = share(uniqueMountPoint(), of: hal)
    let music = share(uniqueMountPoint(), of: hal)
    let movies = share(uniqueMountPoint(), of: hal)
    let stub = StubSidebarVolumes([main, music, movies])
    stub.fail(main.mountPoint, with: "In use.")
    stub.fail(movies.mountPoint, with: "Busy.")
    let volumes = stub.list()
    await settle { volumes.volumes.count == 3 }

    await #expect(
        throws: SidebarVolume.ServerEjectFailure(refusals: [
            .init(name: main.name, reason: "In use."), .init(name: movies.name, reason: "Busy."),
        ])
    ) { try await volumes.ejectServer(hal) }

    #expect(stub.ejects.count == 3)
    // The refused shares can be ejected again; the one that went stays ejecting until a read
    // without it lands.
    #expect(volumes.ejecting == [music.mountPoint])
}

/// A list view's column is made per navigation and observes the list, so observing drops the
/// observers whose owners are gone, with their handlers, rather than only at the next change.
@MainActor @Test func observingDropsTheObserversWhoseOwnersAreGone() async {
    final class Owner {}
    final class Captured {}
    let volumes = StubSidebarVolumes().list()
    weak var captured: Captured?
    do {
        let owner = Owner()
        let held = Captured()
        captured = held
        volumes.observe(for: owner) { _ = held }
    }
    #expect(captured != nil)

    let next = Owner()
    volumes.observe(for: next) {}

    #expect(captured == nil)
    withExtendedLifetime(next) {}
}
