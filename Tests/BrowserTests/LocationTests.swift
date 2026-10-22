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

@Test func childRejectsAnEmptyName() async {
    await #expect(processExitsWith: .failure) { _ = Location(path: "/a").child(named: "") }
}

@Test func childRejectsANameWithASlash() async {
    await #expect(processExitsWith: .failure) { _ = Location(path: "/a").child(named: "b/c") }
}
