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

/// A window at a real temporary folder holding the folders `folders`, which `fill` fills, in
/// `viewMode`, its rows drawn with the app's icon cache and a real thumbnail service, and its
/// folder watched as the app watches it. Nothing is faked; the window is never shown.
@MainActor
private struct IconWindow {
    let folder: TemporaryFolder
    let controller: BrowserWindowController
    let table: NSTableView

    init(
        folders: [String], viewMode: ViewMode, fill: (URL) async throws -> Void = { _ in }
    ) async throws {
        folder = try TemporaryFolder("RowIconTests")
        for name in folders {
            try FileManager.default.createDirectory(
                at: folder.url.appending(path: name), withIntermediateDirectories: false)
        }
        try await fill(folder.url)
        let settings = untouchedSettings()
        let location = Location(path: folder.url.path)
        controller = BrowserWindowController(
            location: location, service: ListingService(thumbnails: ThumbnailService()),
            systemActions: StubSystemActions(), settings: settings,
            favorites: Favorites(settings: settings), volumes: StubSidebarVolumes([]).list())
        let window = try #require(controller.window)
        controller.workspace.selectedTab.focusedPane.setViewMode(viewMode)
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
        await settle { list()?.listing?.count == folders.count }
        table = try #require(list()).tableView
    }

    /// The image each row's name cell shows, after laying the window out as a frame does.
    var icons: [NSImage?] {
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        return (0..<table.numberOfRows).map { row in
            (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NSTableCellView)?
                .imageView?.image
        }
    }

    /// Waits for every row to show an icon other than the folder type's, and returns them.
    func landedIcons() async throws -> [NSImage] {
        let typeIcon = TypeIconCache.shared.icon(for: .folder)
        await settle { icons.allSatisfy { $0 != nil && $0 !== typeIcon } }
        return try icons.map { try #require($0) }
    }
}

/// A folder's row shows the icon Finder draws for that folder, which Quick Look makes, in place
/// of the folder type's: a folder with an item in it a sheet of paper between its flaps, an empty
/// one none, a tagged one its tag's grey (fb-1028b-1.jpg, fb-1028b-2.jpg;
/// docs/decisions/0129-row-icons-as-finder.md).
@MainActor @Test(arguments: [ViewMode.list, .column])
func aFoldersRowShowsTheIconFinderDrawsForThatFolder(viewMode: ViewMode) async throws {
    let window = try await IconWindow(folders: ["empty", "full", "tagged"], viewMode: viewMode) {
        for name in ["full", "tagged"] {
            try Data("a".utf8).write(to: $0.appending(path: "\(name)/a.txt"))
        }
        try await setTags(["Gray\n1"], at: $0.appending(path: "tagged").path)
    }

    let shown = try await window.landedIcons()

    // Finder's list view draws 16-point icons, its column view 18-point ones
    // (docs/decisions/0135-list-rows-as-finder.md).
    let side = viewMode == .list ? 16.0 : 18.0
    #expect(shown.allSatisfy { $0.size == NSSize(width: side, height: side) })
    let (empty, full, tagged) = (try pixels(shown[0]), try pixels(shown[1]), try pixels(shown[2]))
    #expect(empty != full)
    #expect(full != tagged)
}

/// A file made in an empty child folder of a pane's folder changes that folder's icon to the
/// full one, and removing it changes it back, as the folder's watch reads the child again
/// (docs/decisions/0129-row-icons-as-finder.md).
@MainActor @Test(arguments: [ViewMode.list, .column])
func aChildFoldersIconFollowsItsItemsComingAndGoing(viewMode: ViewMode) async throws {
    let window = try await IconWindow(folders: ["sub"], viewMode: viewMode)
    let empty = try pixels(try #require(try await window.landedIcons().first))
    let item = window.folder.url.appending(path: "sub/a.txt")
    let shown = { () -> [UInt8]? in
        guard let icon = window.icons.first ?? nil else { return nil }
        return try? pixels(icon)
    }

    try Data("a".utf8).write(to: item)
    await settle { shown().map { $0 != empty } ?? false }
    #expect(shown().map { $0 != empty } ?? false)

    try FileManager.default.removeItem(at: item)
    await settle { shown() == empty }
    #expect(shown() == empty)
}
