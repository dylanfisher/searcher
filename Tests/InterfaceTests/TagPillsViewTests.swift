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
    #expect(try pills.pills.allSatisfy { try !isTruncated($0.label) })
    // VoiceOver reads the Tags title, then each pill's name.
    let fields = try #require(preview.accessibilityChildren() as? [NSTextField])
    #expect(fields.suffix(4).map(\.stringValue) == ["Tags", "Orange", "Work", "Blue"])
}

/// Whether `label` cuts its text short with an ellipsis where it is now.
@MainActor
private func isTruncated(_ label: NSTextField) throws -> Bool {
    let cell = try #require(label.cell)
    return cell.expansionFrame(withFrame: label.bounds, in: label) != .zero
}

/// Dylan, 2026-10-28, of a "Yellow" pill drawn "Yell…": "tags shouldnt be truncated. this is
/// finder … unless they actually are really long and need to be truncated". Through a real
/// window, a short name shows whole in a preview of the usual width, and only a name wider than
/// the preview is cut short, its pill as wide as the preview
/// (docs/decisions/0127-tag-colors-and-pill-widths.md).
@MainActor @Test func aPillShowsItsWholeNameUnlessItIsWiderThanThePreview() async throws {
    let long = String(repeating: "A tag with a very long name ", count: 6)
    let window = try await TaggingWindow(
        [("a.txt", ["Yellow\n5", "Work\n0", "\(long)\n4"])], viewMode: .column)

    try window.folderPane.select(Selection([ExactName("a.txt")], cursor: ExactName("a.txt")))
    let columns = window.paneController.columnViewController
    await settle { columns.previewView?.tagPills.names == ["Yellow", "Work", long] }
    columns.view.layoutSubtreeIfNeeded()

    let pills = try #require(columns.previewView?.tagPills)
    #expect(pills.bounds.width > 100)
    #expect(try !isTruncated(pills.pills[0].label))
    #expect(try !isTruncated(pills.pills[1].label))
    #expect(try isTruncated(pills.pills[2].label))
    #expect(pills.pills[2].frame.minX == 0 && pills.pills[2].frame.width == pills.bounds.width)
}

/// A pill laid out narrow, as one can be before the preview has its width, shows its whole
/// name once it is widened to fit it.
@MainActor @Test func aPillWidenedToItsNameShowsItWhole() throws {
    let pill = TagPillView(name: "Yellow", label: 5)
    pill.frame = NSRect(x: 0, y: 0, width: 20, height: pill.fittingSize.height)
    pill.layoutSubtreeIfNeeded()

    pill.frame.size = pill.fittingSize
    pill.layoutSubtreeIfNeeded()

    #expect(try !isTruncated(pill.label))
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

/// Over white, a pill's fill comes within 4 a component of Finder's in Dylan's screenshots,
/// Display P3 0 to 255: "Yellow" on 2026-10-28 and "Orange" on 2026-10-27
/// (docs/decisions/0127-tag-colors-and-pill-widths.md).
@MainActor @Test(arguments: [(5, [250, 224, 139] as [CGFloat]), (7, [247, 188, 137])])
func aPillOverWhiteIsFilledAsFindersIs(_ label: Int, _ finder: [CGFloat]) throws {
    let pill = TagPillView(name: "Tag", label: label)
    var fill: NSColor?
    try #require(NSAppearance(named: .aqua)).performAsCurrentDrawingAppearance {
        fill = pill.fill.usingColorSpace(.displayP3)
    }
    let color = try #require(fill)
    let alpha = color.alphaComponent
    let overWhite = [color.redComponent, color.greenComponent, color.blueComponent].map {
        ($0 * alpha + (1 - alpha)) * 255
    }
    #expect(zip(overWhite, finder).allSatisfy { abs($0 - $1) <= 4 }, "\(overWhite)")
}
