import Base
import Testing

@Test func theLastComponentIsTheNameAPathEndsIn() {
    #expect(lastComponent(of: "/Users/me/notes.txt") == "notes.txt")
    #expect(lastComponent(of: "/Users/me/") == "me")
    #expect(lastComponent(of: "notes.txt") == "notes.txt")
}

@Test func theRootsLastComponentIsTheRoot() {
    #expect(lastComponent(of: "/") == "/")
    #expect(lastComponent(of: "/notes.txt") == "notes.txt")
}

@Test func anEmptyPathHasNoLastComponent() {
    #expect(lastComponent(of: "") == "")
}

@Test func theLastComponentKeepsUnicodeNamesAsTheyAre() {
    #expect(lastComponent(of: "/Users/me/Ünïcødé 📁/café.txt") == "café.txt")
}
