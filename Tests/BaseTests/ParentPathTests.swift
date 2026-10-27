import Base
import Testing

@Test func theParentOfAPathIsTheFolderThatHoldsIt() {
    #expect(parentPath(of: "/Users/me/notes.txt") == "/Users/me")
    #expect(parentPath(of: "/Users/me/") == "/Users")
}

@Test func theParentOfAnItemAtTheRootAndOfTheRootIsTheRoot() {
    #expect(parentPath(of: "/notes.txt") == "/")
    #expect(parentPath(of: "/") == "/")
}

@Test func aBareNameAndAnEmptyPathHaveNoParent() {
    #expect(parentPath(of: "notes.txt") == "")
    #expect(parentPath(of: "") == "")
}

@Test func theParentKeepsUnicodeNamesAsTheyAre() {
    #expect(parentPath(of: "/Users/me/Ünïcødé 📁/café.txt") == "/Users/me/Ünïcødé 📁")
}
