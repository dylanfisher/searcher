import Browser
import Testing

@Test func rootIsNamedSlash() {
    #expect(Location(path: "/").name == "/")
}

@Test func parentDropsTheLastComponent() {
    #expect(Location(path: "/a/b/c").parent == Location(path: "/a/b"))
    #expect(Location(path: "/a").parent == Location(path: "/"))
}

@Test func parentOfRootIsNil() {
    #expect(Location(path: "/").parent == nil)
}

@Test func childAppendsAName() {
    #expect(Location(path: "/a").child(named: "b") == Location(path: "/a/b"))
    #expect(Location(path: "/").child(named: "b") == Location(path: "/b"))
}

@Test func ancestorsRunFromRootToTheLocation() {
    #expect(
        Location(path: "/Users/dylan/Projects").ancestors == [
            Location(path: "/"), Location(path: "/Users"), Location(path: "/Users/dylan"),
            Location(path: "/Users/dylan/Projects"),
        ])
}

@Test func rootIsItsOnlyAncestor() {
    #expect(Location(path: "/").ancestors == [Location(path: "/")])
}

@Test func childRejectsAnEmptyName() async {
    await #expect(processExitsWith: .failure) { _ = Location(path: "/a").child(named: "") }
}

@Test func childRejectsANameWithASlash() async {
    await #expect(processExitsWith: .failure) { _ = Location(path: "/a").child(named: "b/c") }
}

private let hal = Location.server(Server(mountSource: "//dylan@HAL9000._smb._tcp.local/music")!)

@Test func aPathMakesAFolder() {
    #expect(Location(path: "/a") == .folder(path: "/a"))
    #expect(Location(path: "/a").folderPath == "/a")
    #expect(Location(path: "/a").path == "/a")
    #expect(Location(path: "/a").isFolder)
}

@Test func aServerIsNoFolderAndHasNoPath() {
    #expect(!hal.isFolder)
    #expect(hal.path == nil)
}

@Test func aServerHasNoFolderPath() async {
    await #expect(processExitsWith: .failure) {
        _ = Location.server(Server(mountSource: "//HAL9000._smb._tcp.local/music")!).folderPath
    }
}

@Test func serversAreEqualAndHashAlikeWhenTheirHostsAreWithoutCase() {
    let other = Location.server(Server(mountSource: "//guest@hal9000._SMB._tcp.local/main")!)
    #expect(hal == other)
    #expect(Set([hal, other]).count == 1)
    #expect(hal != Location.server(Server(mountSource: "//192.168.1.5/music")!))
    #expect(hal != Location(path: "/Volumes/music"))
}

@Test func aServerIsNamedByItsServer() {
    #expect(hal.name == "HAL9000")
}

@Test func aServerHasNoParentAndIsItsOnlyAncestor() {
    #expect(hal.parent == nil)
    #expect(hal.ancestors == [hal])
}

@Test func aServersChildIsItsShareInVolumes() {
    #expect(hal.child(named: "music") == Location(path: "/Volumes/music"))
}

@Test func aServersChildRejectsANameWithASlash() async {
    await #expect(processExitsWith: .failure) {
        _ = Location.server(Server(mountSource: "//HAL9000._smb._tcp.local/music")!)
            .child(named: "a/b")
    }
}
