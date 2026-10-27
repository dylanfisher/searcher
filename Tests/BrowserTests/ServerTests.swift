import Browser
import Testing

@Test(arguments: [
    ("//dylan@HAL9000._smb._tcp.local/music", "HAL9000._smb._tcp.local"),
    ("//HAL9000._smb._tcp.local/main", "HAL9000._smb._tcp.local"),
    ("//dylan@nas.example.com:445/share", "nas.example.com"),
    ("//dylan;WORKGROUP@nas/share", "nas"),
    ("//user:secret@nas/share", "nas"),
    ("//nas/share/sub/folder", "nas"),
    ("afp://dylan@nas.local/share", "nas.local"),
    ("https://dav.example.com/remote.php/dav/files/dylan", "dav.example.com"),
    ("http://dylan@dav.example.com:8080/", "dav.example.com"),
    ("webdav://dav.example.com", "dav.example.com"),
    ("nas.local:/export/home", "nas.local"),
    ("192.168.1.5:/export", "192.168.1.5"),
    ("[fe80::1]:/export", "fe80::1"),
    ("//dylan@192.168.1.5/share", "192.168.1.5"),
    ("//user@[fe80::1%en0]/share", "fe80::1%en0"),
    ("//user@[2001:db8::1]:445/share", "2001:db8::1"),
    ("//dylan%40work@nas/My%20Share", "nas"),
    ("//Dylan%20Fisher@nas/Caf%C3%A9", "nas"),
])
func eachSourceFormNamesItsHost(source: String, host: String) throws {
    #expect(try #require(Server(mountSource: source)).host == host)
}

@Test(arguments: [
    "/dev/disk3s1", "/dev/disk1s4s1", "devfs", "map auto_home", "map -hosts",
    "com.apple.TimeMachine.2026-10-26-120000.backup@/dev/disk5s2", "", "//", "///share",
    "//nas", "//nas/", "//user@/share", "//[fe80::1/share", "//nas:port/share", "://nas/share",
    "1http://nas/share", ":/export", "/Volumes/music:/x", "[fe80::1]/export",
])
func aSourceThatNamesNoHostHasNoServer(source: String) {
    #expect(Server(mountSource: source) == nil)
}

@Test func aBonjourHostIsNamedByItsInstance() throws {
    #expect(
        try #require(Server(mountSource: "//dylan@HAL9000._smb._tcp.local/music")).name
            == "HAL9000")
    #expect(
        try #require(Server(mountSource: "afp://nas._afpovertcp._tcp.local/share")).name == "nas")
}

@Test(arguments: [
    ("//d@Dylan\\032Fisher\\226\\128\\153s\\032Mac._smb._tcp.local/s", "Dylan Fisher’s Mac"),
    ("//d@My\\.Server._smb._tcp.local/s", "My.Server"),
    ("//d@Back\\\\slash._smb._tcp.local/s", "Back\\slash"),
    ("//d@A\\(1\\)._smb._tcp.local/s", "A(1)"),
    ("//d@Dylan%27s%20Mac._smb._tcp.local/s", "Dylan's Mac"),
    ("//d@Caf%C3%A9._smb._tcp.local/s", "Café"),
])
func aBonjourInstanceHasItsEscapesUndone(source: String, name: String) throws {
    #expect(try #require(Server(mountSource: source)).name == name)
}

@Test(arguments: [
    "//d@Bad%5C._smb._tcp.local/s", "//d@Big\\256._smb._tcp.local/s",
    "//d@Short\\03._smb._tcp.local/s", "//d@Broken\\255._smb._tcp.local/s",
    "//d@Bad%ZZ._smb._tcp.local/s",
])
func aBonjourInstanceWhoseEscapesDontDecodeHasNoServer(source: String) {
    #expect(Server(mountSource: source) == nil)
}

@Test(arguments: [
    ("//dylan@192.168.1.5/share", "192.168.1.5"),
    ("//user@[fe80::1%en0]/share", "fe80::1%en0"),
    ("//nas.example.com/share", "nas.example.com"),
    ("//d@printer._ipp._tcp/s", "printer._ipp._tcp"),
    ("//d@a._smb.b.local/s", "a._smb.b.local"),
])
func anyOtherHostIsNamedAsWritten(source: String, name: String) throws {
    #expect(try #require(Server(mountSource: source)).name == name)
}

@Test func hostsCompareWithoutCase() throws {
    let upper = try #require(Server(mountSource: "//dylan@HAL9000._smb._tcp.local/music"))
    let lower = try #require(Server(mountSource: "//guest@hal9000._SMB._tcp.LOCAL/main"))
    let other = try #require(Server(mountSource: "//dylan@HAL9001._smb._tcp.local/music"))
    #expect(upper == lower)
    #expect(upper.hashValue == lower.hashValue)
    #expect(Set([upper, lower, other]).count == 2)
    #expect(upper != other)
}

@Test func twoUsersOnOneHostAreOneServer() {
    #expect(
        Server(mountSource: "//dylan@HAL9000._smb._tcp.local/music")
            == Server(mountSource: "//guest@HAL9000._smb._tcp.local/main"))
}

@Test(arguments: [
    "//dylan@HAL9000._smb._tcp.local/music", "//user@[fe80::1%en0]/share",
    "//user@[2001:db8::1]:445/share", "nas.local:/export/home",
    "//d@Dylan\\032Fisher\\226\\128\\153s\\032Mac._smb._tcp.local/s",
])
func aServerMadeFromItsHostIsTheServerOfItsSource(source: String) throws {
    let server = try #require(Server(mountSource: source))
    let again = try #require(Server(host: server.host))
    #expect(again.host == server.host)
    #expect(again.name == server.name)
}

@Test func aHostKeepsItsSpellingAndIsNamedByItsInstance() throws {
    let server = try #require(Server(host: "Hal9000._SMB._tcp.Local"))
    #expect(server.host == "Hal9000._SMB._tcp.Local")
    #expect(server.name == "Hal9000")
}

@Test(arguments: ["", "Bad%ZZ._smb._tcp.local", "Big\\256._smb._tcp.local"])
func aHostThatNamesNoServerHasNone(host: String) {
    #expect(Server(host: host) == nil)
}
