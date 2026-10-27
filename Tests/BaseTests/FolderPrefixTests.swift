import Base
import Testing

@Test func aFoldersPrefixEndsInOneSlash() {
    #expect(folderPrefix("/Users/me") == "/Users/me/")
    #expect(folderPrefix("/Users/me/") == "/Users/me/")
}

@Test func theRootsPrefixIsTheRoot() {
    #expect(folderPrefix("/") == "/")
}

@Test func anEmptyFoldersPrefixIsTheRoot() {
    #expect(folderPrefix("") == "/")
}

@Test func aPrefixKeepsUnicodeNamesAsTheyAre() {
    #expect(folderPrefix("/Users/me/Ünïcødé 📁") == "/Users/me/Ünïcødé 📁/")
}
