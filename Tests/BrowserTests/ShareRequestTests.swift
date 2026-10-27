import BrowserTestSupport
import Testing

@testable import Browser

@Test func theRequestIsTheServerWithTheUserOfItsFirstMountedSMBShare() throws {
    let volumes = [
        mountedShare("photos", of: "nas.local"),
        mountedShare("video", user: "afpuser", fsType: "afpfs"),
        mountedShare("music", user: "DOMAIN;dylan"),
        mountedShare("main", user: "guest"),
    ]
    let request = try #require(ShareRequest(server: testServer, volumes: volumes))
    #expect(request == ShareRequest(server: testServer, user: "DOMAIN;dylan"))
    #expect(request.server.host == testServerHost)
}

@Test func twoUsersOnOneHostMakeTwoRequests() throws {
    let dylans = try #require(
        ShareRequest(
            server: testServer,
            volumes: [mountedShare("music"), mountedShare("main", user: "guest")]))
    let guests = try #require(
        ShareRequest(server: testServer, volumes: [mountedShare("main", user: "guest")]))
    #expect(dylans.user == "dylan")
    #expect(guests.user == "guest")
    #expect(dylans != guests)
}

@Test func aShareMountedWithNoUserAsksWithNone() throws {
    let request = try #require(
        ShareRequest(server: testServer, volumes: [mountedShare("music", user: nil)]))
    #expect(request.user == nil)
}

@Test func aServerWithNoMountedSMBShareHasNoRequest() {
    #expect(ShareRequest(server: testServer, volumes: []) == nil)
    #expect(
        ShareRequest(server: testServer, volumes: [mountedShare("music", fsType: "afpfs")]) == nil)
    #expect(
        ShareRequest(server: testServer, volumes: [mountedShare("music", of: "nas.local")]) == nil)
}

@Test func aFirstShareWhoseSourceDoesNotDecodeHasNoRequest() {
    #expect(
        ShareRequest(
            server: testServer, volumes: [mountedShare("a%2Fb"), mountedShare("music")]) == nil)
    #expect(
        ShareRequest(server: testServer, volumes: [mountedShare("music", user: "bad%zz")]) == nil)
}
