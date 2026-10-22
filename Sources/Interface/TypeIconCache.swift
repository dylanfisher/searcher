import AppKit
import UniformTypeIdentifiers

/// One icon per file type, shared by every row of that type. Lists show type icons only, never
/// per-file icons or thumbnails, which cost 85 ms per file over SMB (0004-listing-view.md).
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

    public func icon(for type: UTType) -> NSImage {
        if let icon = icons[type] {
            return icon
        }
        let icon = makeIcon(type)
        icons[type] = icon
        return icon
    }
}
