import Base
import Testing

@Test func theFolderItselfAndPathsUnderItAreAtOrUnderIt() {
    #expect(isPath("/Volumes/share", atOrUnder: "/Volumes/share"))
    #expect(isPath("/Volumes/share/music", atOrUnder: "/Volumes/share"))
    #expect(isPath("/Volumes/share/music", atOrUnder: "/Volumes/share/"))
}

@Test func aPathThatOnlyStartsWithTheFoldersTextIsNotUnderIt() {
    #expect(!isPath("/Volumes/shared", atOrUnder: "/Volumes/share"))
    #expect(!isPath("/Volumes", atOrUnder: "/Volumes/share"))
}

@Test func everyAbsolutePathIsUnderTheRoot() {
    #expect(isPath("/", atOrUnder: "/"))
    #expect(isPath("/Users/me", atOrUnder: "/"))
}
