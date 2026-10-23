import AppKit
import Foundation
import Testing

@testable import Interface

/// A pasteboard of the test's own, so a test never writes the user's clipboard. Released when
/// `body` returns.
@MainActor
private func withTestPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("searcher-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    try body(pasteboard)
}

private let files = [
    URL(fileURLWithPath: "/Users/someone/report 3.txt"),
    URL(fileURLWithPath: "/Users/someone/Café/notes"),
]

@MainActor @Test func writePutsOneFileURLItemPerFileAndTheNamesAsText() throws {
    try withTestPasteboard { pasteboard in
        let clipboard = PasteboardFileClipboard(pasteboard: pasteboard)

        clipboard.write(files)

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.map { $0.string(forType: .fileURL) } == files.map(\.absoluteString))
        #expect(pasteboard.string(forType: .string) == "report 3.txt\nnotes")
    }
}

@MainActor @Test func filesWrittenAsFinderWritesThemReadBack() throws {
    withTestPasteboard { pasteboard in
        // Finder's Copy: one item per file, each with its file URL, and the names as text.
        pasteboard.clearContents()
        let items = files.map { url in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        items[0].setString("report 3.txt\rnotes", forType: .string)
        #expect(pasteboard.writeObjects(items))

        #expect(PasteboardFileClipboard(pasteboard: pasteboard).fileURLs() == files)
    }
}

@MainActor @Test func filesWrittenAsURLObjectsReadBack() throws {
    withTestPasteboard { pasteboard in
        pasteboard.clearContents()
        #expect(pasteboard.writeObjects(files.map { $0 as NSURL }))

        #expect(PasteboardFileClipboard(pasteboard: pasteboard).fileURLs() == files)
    }
}

@MainActor @Test func textAndWebURLsReadAsNoFiles() throws {
    try withTestPasteboard { pasteboard in
        let clipboard = PasteboardFileClipboard(pasteboard: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("/Users/someone/report 3.txt", forType: .string)
        #expect(clipboard.fileURLs().isEmpty)

        pasteboard.clearContents()
        let web = try #require(URL(string: "https://example.com"))
        #expect(pasteboard.writeObjects([web as NSURL]))
        #expect(clipboard.fileURLs().isEmpty)
    }
}

@MainActor @Test func eachWriteRaisesTheChangeCount() throws {
    withTestPasteboard { pasteboard in
        let clipboard = PasteboardFileClipboard(pasteboard: pasteboard)
        let before = clipboard.changeCount

        clipboard.write(files)
        let afterOne = clipboard.changeCount
        pasteboard.clearContents()

        #expect(afterOne > before)
        #expect(clipboard.changeCount > afterOne)
        #expect(clipboard.changeCount == pasteboard.changeCount)
    }
}
