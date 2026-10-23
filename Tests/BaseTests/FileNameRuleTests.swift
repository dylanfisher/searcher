import Base
import Testing

@Test(arguments: [
    "report.txt", ".zshrc", "App.app", "a b", "...", "名前", String(repeating: "a", count: 255),
    // 127 two-byte characters: 254 UTF-8 bytes.
    String(repeating: "é", count: 127),
])
func validNamesHaveNoProblem(_ name: String) {
    #expect(FileNameRule.problem(with: name) == nil)
}

@Test func emptyNameIsRejected() {
    #expect(FileNameRule.problem(with: "") == .empty)
}

@Test func dotAndDotDotAreRejected() {
    #expect(FileNameRule.problem(with: ".") == .dotOrDotDot)
    #expect(FileNameRule.problem(with: "..") == .dotOrDotDot)
}

@Test func slashIsRejected() {
    #expect(FileNameRule.problem(with: "a/b") == .slash)
}

/// Finder refuses a name with a colon: it stores the "/" a user types as ":" on disk.
@Test func colonIsRejected() {
    #expect(FileNameRule.problem(with: "a:b") == .colon)
}

/// A NUL would end the name early in the system call, so a different name would be created.
@Test func nulIsRejected() {
    #expect(FileNameRule.problem(with: "a\0b") == .nul)
}

/// The limit counts UTF-8 bytes, not characters: 128 "é" are 128 characters and 256 bytes.
@Test func namesOver255UTF8BytesAreRejected() {
    #expect(FileNameRule.problem(with: String(repeating: "a", count: 256)) == .tooLong)
    #expect(FileNameRule.problem(with: String(repeating: "é", count: 128)) == .tooLong)
}
