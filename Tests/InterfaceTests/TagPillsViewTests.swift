import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

// The column preview shows each tag as a pill in its color, as Finder's preview does
// (docs/decisions/0124-tags-in-rows-and-preview.md).

/// Through a real window over a real folder: the preview reads the file's tags with their
/// colors and shows a pill for each, filled with the tag's color, and a light gray one for a tag
/// without a color.
@MainActor @Test func thePreviewShowsEachTagAsAPillInItsColor() async throws {
    let window = try await TaggingWindow(
        [("a.txt", ["Orange\n7", "Work\n0", "Blue\n4"])], viewMode: .column)

    try window.folderPane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let columns = window.paneController.columnViewController
    await settle { columns.previewView?.tagPills.names == ["Orange", "Work", "Blue"] }
    let preview = try #require(columns.previewView)
    columns.view.layoutSubtreeIfNeeded()

    let pills = preview.tagPills
    #expect(!pills.isHidden)
    #expect(pills.pills.map(\.colorLabel) == [7, 0, 4])
    #expect(pills.pills[0].fill == NSColor.tagLabel(7).withAlphaComponent(TagPillView.fillAlpha))
    #expect(pills.pills[1].fill == .quaternaryLabelColor)
    #expect(pills.pills.allSatisfy { $0.label.textColor == .labelColor })
    // In a row, each as wide as its name and its padding, and wholly shown.
    #expect(pills.pills.allSatisfy { $0.frame.size == $0.fittingSize })
    #expect(pills.pills[1].frame.minX == pills.pills[0].frame.maxX + TagPillsView.spacing)
    #expect(pills.pills.allSatisfy { $0.label.frame.width >= $0.label.intrinsicContentSize.width })
    // VoiceOver reads the Tags title, then each pill's name.
    let fields = try #require(preview.accessibilityChildren() as? [NSTextField])
    #expect(fields.suffix(4).map(\.stringValue) == ["Tags", "Orange", "Work", "Blue"])
}

@MainActor @Test func pillsWrapBeforeOneThatWouldPassTheWidth() {
    let size = NSSize(width: 40, height: 16)

    let frames = TagPillsView.frames(of: [size, size, size], width: 90)

    let spacing = TagPillsView.spacing
    #expect(frames[0].origin == .zero)
    #expect(frames[1].origin == NSPoint(x: 40 + spacing, y: 0))
    #expect(frames[2].origin == NSPoint(x: 0, y: 16 + spacing))
}

@MainActor @Test func aPillWiderThanTheRowTakesItAndIsNarrowedToIt() {
    let frames = TagPillsView.frames(
        of: [NSSize(width: 30, height: 16), NSSize(width: 200, height: 16)], width: 100)

    #expect(frames[1] == NSRect(x: 0, y: 16 + TagPillsView.spacing, width: 100, height: 16))
}
