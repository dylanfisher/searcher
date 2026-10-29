import AppKit
import Base
import BrowserTestSupport
import Foundation
import TestSupport
import Testing

@testable import Browser
@testable import Interface

/// The RGBA bytes `image` draws at its own size at scale 2, in the light appearance.
@MainActor
private func pixels(_ image: NSImage) throws -> [UInt8] {
    let bitmap = try #require(
        NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(image.size.width * 2),
            pixelsHigh: Int(image.size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
            bitsPerPixel: 0))
    bitmap.size = image.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSAppearance(named: .aqua)?.performAsCurrentDrawingAppearance {
        image.draw(in: NSRect(origin: .zero, size: image.size))
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = try #require(bitmap.bitmapData)
    return Array(UnsafeBufferPointer(start: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
}

/// A window at a real temporary folder, in `viewMode`, whose rows are drawn with the app's icon
/// cache and thumbnail service: a folder with an item in it, an empty one, and a tagged one with
/// an item in it. A folder's row shows the icon Finder draws for that folder, which Quick Look
/// makes, in place of the folder type's: the full one a sheet of paper between its flaps, the
/// tagged one its tag's grey (fb-1028b-1.jpg, fb-1028b-2.jpg;
/// docs/decisions/0129-row-icons-as-finder.md).
@MainActor @Test(arguments: [ViewMode.list, .column])
func aFoldersRowShowsTheIconFinderDrawsForThatFolder(viewMode: ViewMode) async throws {
    let folder = try TemporaryFolder("RowIconTests")
    for name in ["empty", "full", "tagged"] {
        try FileManager.default.createDirectory(
            at: folder.url.appending(path: name), withIntermediateDirectories: false)
    }
    for name in ["full", "tagged"] {
        try Data("a".utf8).write(to: folder.url.appending(path: "\(name)/a.txt"))
    }
    try await setTags(["Gray\n1"], at: folder.url.appending(path: "tagged").path)
    let settings = untouchedSettings()
    let location = Location(path: folder.url.path)
    let controller = BrowserWindowController(
        location: location, service: ListingService(thumbnails: ThumbnailService()),
        systemActions: StubSystemActions(), settings: settings,
        favorites: Favorites(settings: settings), volumes: StubSidebarVolumes([]).list())
    let window = try #require(controller.window)
    let pane = controller.workspace.selectedTab.focusedPane
    pane.setViewMode(viewMode)
    window.contentView?.layoutSubtreeIfNeeded()
    let paneController = try #require(
        controller.paneViewController(for: controller.workspace.selectedTab.layout.focused))
    let list = {
        viewMode == .list
            ? paneController.listingViewController
            : paneController.columnViewController.columnControllers.first {
                $0.pane.location == location
            }
    }
    await settle { list()?.listing?.count == 3 }
    let table = try #require(list()).tableView
    let typeIcon = TypeIconCache.shared.icon(for: .folder)
    let icons = {
        window.contentView?.layoutSubtreeIfNeeded()
        return (0..<3).map { row in
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?
                .imageView?.image
        }
    }
    await settle { icons().allSatisfy { $0 != nil && $0 !== typeIcon } }

    let shown = try icons().map { try #require($0) }
    #expect(shown.allSatisfy { $0 !== typeIcon && $0.size == NSSize(width: 18, height: 18) })
    let (empty, full, tagged) = (try pixels(shown[0]), try pixels(shown[1]), try pixels(shown[2]))
    #expect(empty != full)
    #expect(full != tagged)
}
