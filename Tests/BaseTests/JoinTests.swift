import Base
import Testing

@Test func joinPutsTheNameInTheFolder() {
    #expect(join("/Users/me", "notes.txt") == "/Users/me/notes.txt")
    #expect(join("/Users/me/", "notes.txt") == "/Users/me/notes.txt")
}

@Test func joinInTheRootGivesOneSlash() {
    #expect(join("/", "Users") == "/Users")
}

@Test func joinInAnEmptyFolderStartsAtTheRoot() {
    #expect(join("", "Users") == "/Users")
}

@Test func joinKeepsUnicodeNamesAsTheyAre() {
    #expect(join("/Users/me/Ünïcødé 📁", "café.txt") == "/Users/me/Ünïcødé 📁/café.txt")
}
