import AppKit
import Browser
import Foundation
import TestSupport
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

private let entries = [file("a.txt"), folder("sub"), file("c.txt")]

@MainActor @Test func theListTakesFileURLAndStringServicesWithASelection() async throws {
    let list = await controller(showing: entries)
    list.pane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))

    let fileNames = NSPasteboard.PasteboardType("NSFilenamesPboardType")
    for type in [NSPasteboard.PasteboardType.fileURL, fileNames, .string] {
        #expect(list.validRequestor(forSendType: type, returnType: nil) as AnyObject? === list)
    }
    // It sends; it takes nothing back.
    #expect(list.validRequestor(forSendType: .fileURL, returnType: .string) == nil)
    #expect(list.validRequestor(forSendType: .tiff, returnType: nil) == nil)
}

@MainActor @Test func theListTakesNoServiceWithNothingSelected() async throws {
    let list = await controller(showing: entries)

    #expect(list.validRequestor(forSendType: .fileURL, returnType: nil) == nil)
    withTestPasteboard { pasteboard in
        #expect(!list.writeSelection(to: pasteboard, types: [.fileURL]))
    }
}

@MainActor @Test func theListWritesTheSelectionsFileURLsAsCopyDoes() async throws {
    let list = await controller(showing: entries)
    let selected = Set(["a.txt", "sub"].map(ExactName.init))
    list.pane.select(Selection(selected, cursor: ExactName("sub")))
    await settle { list.pane.selection.isSettled }

    try withTestPasteboard { pasteboard in
        #expect(list.writeSelection(to: pasteboard, types: [.fileURL, .string]))

        let items = try #require(pasteboard.pasteboardItems)
        #expect(
            items.compactMap { $0.string(forType: .fileURL) } == [
                "file:///folder/a.txt", "file:///folder/sub/",
            ])
        #expect(pasteboard.string(forType: .string) == "a.txt\nsub")
        // A service asking for the older file names type reads the same files.
        #expect(
            pasteboard.propertyList(forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
                as? [String] == ["/folder/a.txt", "/folder/sub"])
    }
}
