import AppKit
import Browser
import UniformTypeIdentifiers

/// One icon per file type, shared by every row of that type. Rows show no per-file icons; a
/// file's thumbnail replaces its type icon only once made, for local files
/// (0004-listing-view.md, 0102-thumbnails.md).
@MainActor
public final class TypeIconCache {
    /// The cache the app's listings share.
    public static let shared = TypeIconCache()

    /// The CoreTypes icon a server's share rows show, Finder's for a share.
    nonisolated static let shareIconName = "GenericSharepoint"

    private let makeIcon: @MainActor (UTType) -> NSImage
    private var icons: [UTType: NSImage] = [:]
    private let readIcons: @Sendable ([String]) async -> [String: Data]
    /// The read of the share icon, started the first time a row asks for it.
    private var shareIconRead: Task<Void, Never>?
    private var readShareIcon: NSImage?
    /// What runs once the share icon's read lands, for the calls made while it ran.
    private var shareIconWaiters: [@MainActor () -> Void] = []

    /// `makeIcon` is called once per type. Rows share the image it returns, so callers must not
    /// change it. `readIcons` gives the bytes of the CoreTypes icon files named, as
    /// `CoreTypesIcons.read` does; tests replace it.
    public init(
        makeIcon: @escaping @MainActor (UTType) -> NSImage = { NSWorkspace.shared.icon(for: $0) },
        readIcons: @escaping @Sendable ([String]) async -> [String: Data] = CoreTypesIcons.read
    ) {
        self.makeIcon = makeIcon
        self.readIcons = readIcons
    }

    /// The icon of a server's share row: CoreTypes' `GenericSharepoint`, read once off the main
    /// thread as the sidebar's glyphs are (`CoreTypesIcons`), and decoded here from memory. Until
    /// the read lands, and if the bundle lacks it, a volume's type icon stands in. The first call
    /// starts the read; `shown` runs once it lands with the icon, for every call made while it
    /// ran, so rows on screen can take it (docs/decisions/0114-server-location.md).
    func shareIcon(shown: @escaping @MainActor () -> Void) -> NSImage {
        if let readShareIcon { return readShareIcon }
        guard shareIconRead == nil || !shareIconWaiters.isEmpty else {
            // Read already, and the bundle has no such icon.
            return icon(for: .volume)
        }
        shareIconWaiters.append(shown)
        if shareIconRead == nil {
            shareIconRead = Task { [readIcons] in
                let files = await readIcons([Self.shareIconName])
                let waiters = shareIconWaiters
                shareIconWaiters = []
                guard let data = files[Self.shareIconName], let image = NSImage(data: data) else {
                    return
                }
                readShareIcon = image
                for waiter in waiters { waiter() }
            }
        }
        return icon(for: .volume)
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
