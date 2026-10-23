import Base
import Foundation
import TestSupport
import Testing

/// Names taken in a folder, compared without case as on a case-insensitive volume.
private func taken(_ names: [String]) -> (String) -> Bool {
    let folded = Set(names.map { $0.lowercased() })
    return { folded.contains($0.lowercased()) }
}

/// One row: the item's name, the names already in the folder, and the name expected.
struct NameCase: Sendable, CustomTestStringConvertible {
    let name: String
    let existing: [String]
    let expected: String

    init(_ name: String, _ existing: [String], _ expected: String) {
        self.name = name
        self.existing = existing
        self.expected = expected
    }

    var testDescription: String { "\(name) with \(existing) -> \(expected)" }
}

/// Every row is what `NSWorkspace.duplicate` returned for the same item and folder on macOS
/// 26.6.2 (Mac17,6), on 2026-10-22. Its documentation says it duplicates as Finder does. The items
/// are files, except where the name says folder or package; a package was a folder with a
/// `Contents` folder inside.
@Test(arguments: [
    NameCase("report.txt", ["report.txt"], "report copy.txt"),
    NameCase("report.txt", ["report.txt", "report copy.txt"], "report copy 2.txt"),
    NameCase("report.txt", ["report.txt", "report copy 2.txt"], "report copy.txt"),
    NameCase(
        "report.txt", ["report.txt", "report copy.txt", "report copy 3.txt"], "report copy 2.txt"),
    NameCase("report.txt", ["report.txt", "Report Copy.txt"], "report copy 2.txt"),
    NameCase("report copy.txt", ["report copy.txt"], "report copy 2.txt"),
    NameCase("report copy 2.txt", ["report copy 2.txt"], "report copy 3.txt"),
    NameCase("x copy.txt", ["x copy.txt", "x copy 2.txt"], "x copy 3.txt"),
    NameCase("x copy 07.txt", ["x copy 07.txt"], "x copy 8.txt"),
    NameCase("x copy 0.txt", ["x copy 0.txt"], "x copy 1.txt"),
    NameCase("x copy 2 copy.txt", ["x copy 2 copy.txt"], "x copy 2 copy 2.txt"),
    NameCase(" copy.txt", [" copy.txt"], " copy 2.txt"),
    NameCase("copy.txt", ["copy.txt"], "copy copy.txt"),
    NameCase("x Copy.txt", ["x Copy.txt"], "x Copy copy.txt"),
    NameCase("report 2.txt", ["report 2.txt"], "report 2 copy.txt"),
    NameCase("Report 2024.pdf", ["Report 2024.pdf"], "Report 2024 copy.pdf"),
    NameCase("archive.tar.gz", ["archive.tar.gz"], "archive.tar copy.gz"),
    NameCase("archive.tar.gz", ["archive.tar.gz", "archive.tar copy.gz"], "archive.tar copy 2.gz"),
    NameCase("name.with.dots.txt", ["name.with.dots.txt"], "name.with.dots copy.txt"),
    NameCase("x.TXT", ["x.TXT"], "x copy.TXT"),
    NameCase(".zshrc", [".zshrc"], ".zshrc copy"),
    NameCase(".a.b", [".a.b"], ".a.b copy"),
    NameCase("notes", ["notes"], "notes copy"),
    NameCase("file.", ["file."], "file. copy"),
    // No type declares these extensions, so they stay part of the name.
    NameCase("x.qqq", ["x.qqq"], "x.qqq copy"),
    NameCase("Photos.2024", ["Photos.2024"], "Photos.2024 copy"),
    NameCase("a.b c", ["a.b c"], "a.b c copy"),
    // Folders.
    NameCase("Folder", ["Folder"], "Folder copy"),
    NameCase("Stuff.txt", ["Stuff.txt"], "Stuff copy.txt"),
    NameCase("untitled folder 2", ["untitled folder 2"], "untitled folder 2 copy"),
    // Packages.
    NameCase("App.app", ["App.app"], "App copy.app"),
    NameCase("App.app", ["App.app", "App copy.app"], "App copy 2.app"),
    NameCase("Lib.framework", ["Lib.framework"], "Lib copy.framework"),
    NameCase("Doc.rtfd", ["Doc.rtfd"], "Doc copy.rtfd"),
])
func duplicateNamesMatchFinder(_ row: NameCase) {
    #expect(UniqueName.duplicate(of: row.name, isTaken: taken(row.existing)) == row.expected)
}

/// Finder's Keep Both, for an item copied or moved onto a name the folder already has. There is
/// no API that names these. Dylan checked Finder on macOS 26 on 2026-10-22: copying "report 3.jpg"
/// onto a folder's "report 3.jpg" and choosing Keep Both gave "report 3 2.jpg". So " 2", " 3" and
/// on, the first free, go after the whole base, a trailing number included, with the extension
/// rule of `duplicateNamesMatchFinder`.
@Test(arguments: [
    NameCase("report 3.jpg", ["report 3.jpg"], "report 3 2.jpg"),
    NameCase("report.txt", ["report.txt"], "report 2.txt"),
    NameCase("report.txt", ["report.txt", "report 2.txt"], "report 3.txt"),
    NameCase("report.txt", ["report.txt", "report 3.txt"], "report 2.txt"),
    NameCase("report 2.txt", ["report 2.txt"], "report 2 2.txt"),
    NameCase("report 2.txt", ["report 2.txt", "report 2 2.txt"], "report 2 3.txt"),
    NameCase("Report 2024.pdf", ["Report 2024.pdf"], "Report 2024 2.pdf"),
    NameCase("report copy.txt", ["report copy.txt"], "report copy 2.txt"),
    NameCase("archive.tar.gz", ["archive.tar.gz"], "archive.tar 2.gz"),
    NameCase(".zshrc", [".zshrc"], ".zshrc 2"),
    NameCase("App.app", ["App.app"], "App 2.app"),
    NameCase("Folder", ["Folder"], "Folder 2"),
    NameCase("Photos.2024", ["Photos.2024"], "Photos.2024 2"),
    NameCase("2.txt", ["2.txt"], "2 2.txt"),
])
func keepBothNamesMatchFinder(_ row: NameCase) {
    #expect(UniqueName.keepingBoth(row.name, isTaken: taken(row.existing)) == row.expected)
}

/// Finder's New Folder: "untitled folder", then the first free number from 2.
@Test func newFolderNamesCountFromTwo() {
    #expect(UniqueName.newFolder(isTaken: taken([])) == "untitled folder")
    #expect(UniqueName.newFolder(isTaken: taken(["untitled folder"])) == "untitled folder 2")
    #expect(
        UniqueName.newFolder(isTaken: taken(["untitled folder", "untitled folder 2"]))
            == "untitled folder 3")
    #expect(
        UniqueName.newFolder(isTaken: taken(["untitled folder", "untitled folder 3"]))
            == "untitled folder 2")
    #expect(UniqueName.newFolder(isTaken: taken(["untitled folder 2"])) == "untitled folder")
}

/// Finder fails to duplicate a name this long (`NSWorkspace.duplicate` returned "File name too
/// long"); we shorten the name before the suffix instead, so the copy still gets made.
@Test func longNamesAreShortenedToFit() {
    let long = String(repeating: "a", count: 251) + ".txt"
    let copy = UniqueName.duplicate(of: long, isTaken: taken([long]))
    #expect(copy == String(repeating: "a", count: 246) + " copy.txt")
    #expect(copy.utf8.count == FileNameRule.maxBytes)

    // Shortened by whole characters: 2-byte "é" never splits.
    let accented = String(repeating: "é", count: 125) + ".txt"
    let both = UniqueName.keepingBoth(accented, isTaken: taken([accented]))
    #expect(both == String(repeating: "é", count: 124) + " 2.txt")
    #expect(both.utf8.count <= FileNameRule.maxBytes)
}

@Test func isTakenReadsTheFolder() throws {
    let folder = try TemporaryFolder("UniqueNameTests")
    try Data().write(to: folder.url.appending(path: "report.txt"))

    #expect(try UniqueName.isTaken("report.txt", in: folder.url.path))
    #expect(try !UniqueName.isTaken("other.txt", in: folder.url.path))
    #expect(
        throws: FileOperationError(
            reason: .other, path: folder.url.path + "/report.txt/x", errno: ENOTDIR)
    ) {
        try UniqueName.isTaken("x", in: folder.url.path + "/report.txt")
    }
}
