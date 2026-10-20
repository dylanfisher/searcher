import Browser
import Testing

@Test func rootIsNamedSlash() {
    #expect(Location(path: "/").name == "/")
}
