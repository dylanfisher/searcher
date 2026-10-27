import Testing

@testable import Browser

@Test func aRenamedItemStaysInItsFolder() {
    #expect(FileOperation.renamed("/A/music/01.flac", to: "one.flac") == "/A/music/one.flac")
}

@Test func anItemRenamedAtTheRootIsNamedWithOneSlash() {
    #expect(FileOperation.renamed("/notes.txt", to: "todo.txt") == "/todo.txt")
}

@Test func anItemGoesIntoTheRootWithOneSlash() {
    #expect(FileOperation.path(of: "/A/notes.txt", in: "/") == "/notes.txt")
    #expect(FileOperation.path(of: "/A/notes.txt", in: "/B") == "/B/notes.txt")
}
