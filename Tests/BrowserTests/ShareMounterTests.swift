import BrowserTestSupport
import Foundation
import Testing

@testable import Browser

/// The URL a mount of `share` asks for, as the user of the first SMB share in `sources`, each a
/// share's source as the system writes it, mounted at `/Volumes/<n>`.
private func url(of share: String, from sources: [String]) throws -> String {
    let volumes = sources.enumerated().map { index, source in
        VolumeIdentity(
            device: source, mountPoint: "/Volumes/\(index)", kind: .network,
            fsType: VolumeIdentity.smbFSType)
    }
    let server = try #require(volumes.first?.server)
    let request = try #require(ShareRequest(server: server, volumes: volumes))
    return ShareMountRequest(share: request, name: share).url
}

/// A share, the sources of the shares mounted, and the URL a mount of the share asks for.
private let urlCases: [(share: String, sources: [String], url: String)] = [
    ("main", ["//dylan@HAL9000._smb._tcp.local/music"], "smb://dylan@HAL9000._smb._tcp.local/main"),
    ("my share", ["//dylan@HAL/music"], "smb://dylan@HAL/my%20share"),
    ("100%", ["//dylan@HAL/music"], "smb://dylan@HAL/100%25"),
    ("a?b#c/d", ["//dylan@HAL/music"], "smb://dylan@HAL/a%3Fb%23c%2Fd"),
    ("Müsik", ["//dylan@HAL/music"], "smb://dylan@HAL/M%C3%BCsik"),
    ("main", ["//dyl%20an@HAL/my%20music"], "smb://dyl%20an@HAL/main"),
    ("main", ["//d%C3%BClan@HAL/music"], "smb://d%C3%BClan@HAL/main"),
    ("main", ["//WORKGROUP;dylan@HAL/music"], "smb://WORKGROUP;dylan@HAL/main"),
    ("main", ["//dyl%40an%3Ax@HAL/music"], "smb://dyl%40an%3Ax@HAL/main"),
    ("main", ["//HAL/music"], "smb://HAL/main"),
    // A Bonjour instance's escapes are undone and the instance percent-encoded.
    (
        "main", [#"//dyl@My\032Mac._smb._tcp.local/music"#],
        "smb://dyl@My%20Mac._smb._tcp.local/main"
    ),
    (
        "music", [#"//dyl@Dylan\226\128\153s\032MacBook\032Pro._smb._tcp.local/main"#],
        "smb://dyl@Dylan%E2%80%99s%20MacBook%20Pro._smb._tcp.local/music"
    ),
    ("main", [#"//dyl@a\.b._smb._tcp.local/music"#], "smb://dyl@a%2Eb._smb._tcp.local/main"),
    ("main", ["//dylan@[fe80::1%en0]/music"], "smb://dylan@[fe80::1%en0]/main"),
    ("main", ["//dylan@[2001:db8::1]:445/music"], "smb://dylan@[2001:db8::1]/main"),
    (
        "main", ["//dylan@HAL/music", "//guest@HAL/video"],
        "smb://dylan@HAL/main"
    ),
]

/// The user is the first SMB share's, encoded once as `smbutil` gets it, and the share is
/// encoded as one path component (docs/decisions/0115-server-shares.md).
@Test(arguments: urlCases)
func aMountsURLIsBuiltFromTheFirstSharesSource(share: String, sources: [String], expected: String)
    throws
{
    #expect(try url(of: share, from: sources) == expected)
}

/// NetFS takes a `CFURL`: a Mac named with a space or an apostrophe still makes one.
@Test func aBonjourHostWithASpaceMakesAURL() throws {
    let url = try url(
        of: "music", from: [#"//dyl@Dylan\226\128\153s\032MacBook\032Pro._smb._tcp.local/main"#])
    #expect(URL(string: url)?.host(percentEncoded: false) == "Dylan’s MacBook Pro._smb._tcp.local")
}

@Test func twoRequestsForOneShareMatchByItsKey() {
    let dylans = ShareRequest(server: testServer, user: "dylan")
    let main = ShareMountRequest(share: dylans, name: "main")
    #expect(main == ShareMountRequest(share: dylans, name: "MAIN"))
    #expect(main.hashValue == ShareMountRequest(share: dylans, name: "MAIN").hashValue)
    #expect(
        ShareMountRequest(share: dylans, name: "Mu\u{0308}sik")
            == ShareMountRequest(share: dylans, name: "Müsik"))
    #expect(main != ShareMountRequest(share: dylans, name: "music"))
    #expect(
        main
            != ShareMountRequest(
                share: ShareRequest(server: testServer, user: "guest"), name: "main"))
}
