import Testing

@testable import Browser

private let folder = Location(path: "/Users/me/projects/app")
private let home = "/Users/me"

private func expand(_ text: String) -> String? {
    PathInput.location(for: text, in: folder, home: home)?.path
}

@Test func tildeExpandsAgainstHome() {
    #expect(expand("~") == "/Users/me")
    #expect(expand("~/") == "/Users/me")
    #expect(expand("~/Downloads") == "/Users/me/Downloads")
}

@Test func relativePathsExpandAgainstThePanesFolder() {
    #expect(expand("../x") == "/Users/me/projects/x")
    #expect(expand("src") == "/Users/me/projects/app/src")
    #expect(expand("./src/../docs") == "/Users/me/projects/app/docs")
    #expect(expand(".") == "/Users/me/projects/app")
}

/// A server's shares are its folders in `/Volumes`, so a path typed at one starts there
/// (0114-server-location.md).
@Test func relativePathsAtAServerExpandAgainstVolumes() throws {
    let server = Location.server(try #require(Server(host: "HAL9000._smb._tcp.local")))
    func expand(_ text: String) -> String? {
        PathInput.location(for: text, in: server, home: home)?.path
    }

    #expect(expand("music") == "/Volumes/music")
    #expect(expand("music/Albums/..") == "/Volumes/music")
    #expect(expand("..") == "/")
    #expect(expand("~/Downloads") == "/Users/me/Downloads")
    #expect(expand("/tmp") == "/tmp")
}

@Test func absolutePathsAreTidiedButKept() {
    #expect(expand("/tmp") == "/tmp")
    #expect(expand("/usr//local/./bin/") == "/usr/local/bin")
    #expect(expand("/") == "/")
}

@Test func dotDotStopsAtTheRoot() {
    #expect(expand("/../..") == "/")
    #expect(PathInput.location(for: "../../..", in: Location(path: "/a"), home: home)?.path == "/")
}

@Test func surroundingWhitespaceIsIgnored() {
    #expect(expand("  ~/Downloads\n") == "/Users/me/Downloads")
}

@Test func blankInputIsNoPath() {
    #expect(expand("") == nil)
    #expect(expand("   ") == nil)
}

@Test func aTildeNotFollowedBySlashIsAName() {
    #expect(expand("~notes") == "/Users/me/projects/app/~notes")
}
