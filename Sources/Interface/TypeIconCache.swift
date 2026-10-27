import AppKit
import UniformTypeIdentifiers

/// One icon per file type, shared by every row of that type. Rows show no per-file icons; a
/// file's thumbnail replaces its type icon only once made, for local files
/// (0004-listing-view.md, 0102-thumbnails.md).
@MainActor
public final class TypeIconCache {
    /// The cache the app's listings share.
    public static let shared = TypeIconCache()

    private let makeIcon: @MainActor (UTType) -> NSImage
    private var icons: [UTType: NSImage] = [:]

    /// `makeIcon` is called once per type. Rows share the image it returns, so callers must not
    /// change it.
    public init(
        makeIcon: @escaping @MainActor (UTType) -> NSImage = { NSWorkspace.shared.icon(for: $0) }
    ) {
        self.makeIcon = makeIcon
    }

    /// The cloud with a down arrow that Finder shows by an iCloud item that isn't downloaded, made
    /// the first time a row shows it and shared by every such row. A template, so it takes its
    /// view's tint.
    public private(set) lazy var notDownloadedBadge: NSImage = {
        let name = "icloud.and.arrow.down"
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            preconditionFailure("no system symbol named \(name)")
        }
        return image
    }()

    /// The chevron's size and weight, Finder's: about 6 points tall and 3.5 wide, a thin stroke,
    /// beside a name 13 points high (docs/decisions/0046-column-view.md).
    static let folderChevronConfiguration = NSImage.SymbolConfiguration(
        pointSize: 7, weight: .regular, scale: .medium)

    /// The chevron Finder draws at the right of a folder row in column view, made the first time a
    /// column shows one and shared by every such row. A template, so it takes its view's tint.
    public private(set) lazy var folderChevron: NSImage = {
        let name = "chevron.right"
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
            let sized = image.withSymbolConfiguration(Self.folderChevronConfiguration)
        else {
            preconditionFailure("no system symbol named \(name)")
        }
        return sized
    }()

    public func icon(for type: UTType) -> NSImage {
        if let icon = icons[type] {
            return icon
        }
        let icon = makeIcon(type)
        icons[type] = icon
        return icon
    }
}
